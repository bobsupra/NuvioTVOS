import CryptoKit
import Foundation
import Combine

// MARK: - What a check finds

/// What checking a Usenet stream before playing it found: the NZB read for what it
/// lacks itself, and a sample of its articles asked about on the servers (`STAT`, a
/// couple of them downloaded: `BODY`), the way playback checks a release when it
/// starts. Or what playing it showed (`playbackProblem`).
struct UsenetAvailabilityReport: Sendable, Equatable, Codable {
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
    /// Of the articles asked about, the ones downloaded (`BODY`) rather than only asked
    /// about: a provider can still answer `STAT` for an article taken down.
    var downloaded = 0

    /// What playing the stream showed, which makes it incomplete whatever a check found.
    enum PlaybackProblem: String, Sendable, Equatable, Codable {
        /// Playback couldn't start: its first article is gone.
        case wouldNotStart
        /// It started, then turned out too damaged to go on.
        case damaged
    }
    var playbackProblem: PlaybackProblem?
    /// It played on these servers lately (its first seconds came): an available release
    /// whether or not anything was sampled.
    var played = false

    /// Damage this long a run stops playback (`UsenetStreamSession.damageConsecutiveMissing`).
    static let nzbGapsLimit = 3

    var verdict: Verdict {
        let health = UsenetHealthCheck.Result(checked: checked, missing: missing, tailMissing: tailMissing)
        if playbackProblem != nil || !UsenetHealthCheck.isPlayable(health)
            || missingVolumes > 0 || nzbGaps >= Self.nzbGapsLimit {
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
        /// The ones among them to download instead (`BODY`), inside the release.
        var downloads: Set<String> = []
        /// The NZB lacks the release's last article: nothing to ask, it's missing.
        var tailMissingInNZB: Bool
        var nzbGaps: Int
        var missingVolumes: Int
    }

    /// Articles of the sample downloaded rather than only asked about (about 1.5 MB).
    static let bodyProbes = 2

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
        // Two from inside the release are downloaded: a provider can answer STAT for an
        // article taken down (DMCA) that BODY then refuses (451).
        var downloads = Set<String>()
        if samples.count >= 3 {
            for step in 1...bodyProbes {
                downloads.insert(samples[step * (samples.count - 1) / (bodyProbes + 1)])
            }
        }
        var tailMissing = false
        if let last = files.last, let declared = declaredSegments(inSubject: last.subject),
           let lastNumber = last.segments.last?.number, lastNumber < declared {
            tailMissing = true
        }
        return Plan(
            samples: samples,
            downloads: downloads,
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

    /// Asks the servers about the plan's articles, and downloads the ones it says to (any
    /// server that has one counts).
    static func ask(_ plan: Plan, pool: UsenetConnectionPool) async throws -> UsenetAvailabilityReport {
        let found = try await withThrowingTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for id in Set(plan.samples) {
                if plan.downloads.contains(id) {
                    group.addTask {
                        switch try await pool.fetch(messageID: id) {
                        case .body(let body): return (id, !body.isEmpty)
                        case .missing: return (id, false)
                        }
                    }
                } else {
                    group.addTask { (id, try await pool.exists(messageID: id)) }
                }
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
            missingVolumes: plan.missingVolumes,
            downloaded: plan.downloads.count
        )
    }
}

// MARK: - Checking streams from the stream list

/// Checks Usenet streams before they're played: the first ones the stream list shows, by
/// themselves (Settings → Usenet → Check Availability on Usenet).
///
/// Each check downloads the stream's NZB into the NZB cache, so playing it afterwards
/// doesn't download it again; the indexer still counts it as a download. Two checks run
/// at once, over connections of their own (two per server), closed once the checks are
/// done, so playback keeps its own.
///
/// What a release showed is remembered on this Apple TV, for the servers it showed it on
/// (another provider may have what one lacks):
/// - incomplete, by a check or by playing it (it wouldn't start, or turned out too damaged),
///   for `incompleteLifetime`: its card says so and failover passes it by. A check that
///   finds it available clears what a check found; what playing it showed stays;
/// - played (its first seconds came), for `playedLifetime`: its card says so.
/// Kept by a hash of the NZB URL, which can carry an indexer key, never the URL itself, and
/// by a hash of the release name and its size in MB, which another indexer's copy of the
/// same upload shares (like Nuvio on Android TV).
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

    static let rememberedKey = "nuvio.tv.usenet.rememberedReleases"
    nonisolated static let incompleteLifetime: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let playedLifetime: TimeInterval = 14 * 24 * 60 * 60
    static let rememberedLimit = 500

    struct Remembered: Codable, Equatable {
        var report: UsenetAvailabilityReport
        var at: Date
        /// `serversDigest` of the servers it was found on.
        var servers: String

        var lifetime: TimeInterval {
            report.verdict == .incomplete ? UsenetAvailabilityChecker.incompleteLifetime : UsenetAvailabilityChecker.playedLifetime
        }

        func isCurrent(servers: String, now: Date) -> Bool {
            self.servers == servers && now.timeIntervalSince(at) < lifetime
        }
    }

    private var checkedAt: [URL: Date] = [:]
    private var queue: [UsenetStreamSpec] = []
    private var running = 0
    private var pools: [[UsenetServerConfig]: UsenetConnectionPool] = [:]
    private var poolShutdown: Task<Void, Never>?
    /// By `memoryKey(_:)` and by `titleKey(_:spec:)`.
    @Published private var remembered: [String: Remembered] = [:]
    /// The name-and-size key of streams the list showed, by `memoryKey`: what the engine,
    /// which knows only the URL, remembers a release under too. Not published: filled while
    /// the list draws.
    private var titleKeys: [String: String] = [:]
    /// The servers' part of `serversDigest`, until they change.
    private var ownServers: (prefersOwn: Bool, own: [String])?
    private var serversObserver: NSObjectProtocol?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.rememberedKey),
           let saved = try? JSONDecoder().decode([String: Remembered].self, from: data) {
            let now = Date()
            remembered = saved.filter { now.timeIntervalSince($0.value.at) < $0.value.lifetime }
        }
        serversObserver = NotificationCenter.default.addObserver(
            forName: .usenetServersChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ownServers = nil }
        }
    }

    nonisolated static func spec(for stream: NuvioStream) -> UsenetStreamSpec? {
        stream.directURL.flatMap(URL.init(string:)).flatMap(UsenetStreamSpec.init(url:))
    }

    func state(for stream: NuvioStream) -> State? {
        guard let spec = Self.spec(for: stream) else { return nil }
        if let titleKey = Self.titleKey(stream, spec: spec) { titleKeys[Self.memoryKey(spec)] = titleKey }
        return state(for: spec)
    }

    /// This session's check, else what was remembered for these servers.
    func state(for spec: UsenetStreamSpec) -> State? {
        if let state = states[spec.nzbURL] { return state }
        return rememberedEntry(spec).map { .checked($0.report) }
    }

    private func rememberedEntry(_ spec: UsenetStreamSpec) -> Remembered? {
        let servers = serversDigest(spec)
        let now = Date()
        let key = Self.memoryKey(spec)
        if let entry = remembered[key], entry.isCurrent(servers: servers, now: now) { return entry }
        if let titleKey = titleKeys[key], let entry = remembered[titleKey], entry.isCurrent(servers: servers, now: now) {
            return entry
        }
        return nil
    }

    /// The same upload from another indexer: a hash of its release name (letters and digits
    /// only) and its size in MB, and the episode of a pack. nil without a name or a size.
    nonisolated static func titleKey(_ stream: NuvioStream, spec: UsenetStreamSpec) -> String? {
        guard let name = stream.filename, let size = stream.videoSize, size > 0 else { return nil }
        let letters = name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !letters.isEmpty else { return nil }
        let megabytes = Int((Double(size) / 1_000_000).rounded())
        let digest = SHA256.hash(data: Data((String(String.UnicodeScalarView(letters)) + "|\(megabytes)").utf8))
        var key = "title:" + digest.map { String(format: "%02x", $0) }.joined()
        if let file = spec.fileMustInclude, !file.isEmpty { key += "|" + file.lowercased() }
        if let index = spec.fileIdx { key += "|#\(index)" }
        return key
    }

    /// The servers a stream is played from, by host, port and login: what one provider
    /// lacks another may have. Never a password.
    func serversDigest(_ spec: UsenetStreamSpec) -> String {
        let settings = ownServers ?? {
            let own = UsenetSettings.servers().filter(\.isEnabled).map { "\($0.host):\($0.port):\($0.username)" }
            let value = (prefersOwn: UsenetSettings.prefersOwnServers(), own: own)
            self.ownServers = value
            return value
        }()
        let addon = spec.servers.map { "\($0.host):\($0.port):\($0.username ?? "")" }
        let used = settings.prefersOwn && !settings.own.isEmpty ? settings.own : addon + settings.own
        let digest = SHA256.hash(data: Data(Array(Set(used)).sorted().joined(separator: ",").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Its first seconds played (the player read its duration): remembered as available on
    /// these servers.
    func recordPlayed(_ spec: UsenetStreamSpec) {
        var report = UsenetAvailabilityReport(checked: 0, missing: 0, tailMissing: false, nzbGaps: 0, missingVolumes: 0)
        report.played = true
        if case .checked(let current)? = states[spec.nzbURL], current.verdict == .incomplete { return }
        states[spec.nzbURL] = .checked(report)
        checkedAt[spec.nzbURL] = Date()
        remember(spec, report)
    }

    /// A hash of the NZB URL, and the episode of a pack.
    nonisolated static func memoryKey(_ spec: UsenetStreamSpec) -> String {
        var key = UsenetNZBCache.key(for: spec.nzbURL)
        if let file = spec.fileMustInclude, !file.isEmpty { key += "|" + file.lowercased() }
        if let index = spec.fileIdx { key += "|#\(index)" }
        return key
    }

    /// Playback found the stream incomplete: when it started (its check of the release,
    /// or its first article gone) or while it played (too damaged to go on).
    func recordPlayback(_ spec: UsenetStreamSpec, report: UsenetAvailabilityReport) {
        states[spec.nzbURL] = .checked(report)
        checkedAt[spec.nzbURL] = Date()
        remember(spec, report)
    }

    private func remember(_ spec: UsenetStreamSpec, _ report: UsenetAvailabilityReport) {
        let key = Self.memoryKey(spec)
        let keys = [key] + (titleKeys[key].map { [$0] } ?? [])
        if report.verdict == .incomplete || report.played {
            if report.played {
                usenetLog.notice("usenet: remembered as played on these servers")
            } else {
                let reason = report.playbackProblem?.rawValue ?? "\(report.missing)/\(report.checked) sampled articles missing"
                usenetLog.notice("usenet: remembered as incomplete (\(reason, privacy: .public))")
            }
            let entry = Remembered(report: report, at: Date(), servers: serversDigest(spec))
            for key in keys { remembered[key] = entry }
            while remembered.count > Self.rememberedLimit,
                  let oldest = remembered.min(by: { $0.value.at < $1.value.at })?.key {
                remembered[oldest] = nil
            }
        } else if keys.contains(where: { remembered[$0]?.report.verdict == .incomplete }) {
            usenetLog.notice("usenet: found \(report.verdict.rawValue, privacy: .public), no longer remembered as incomplete")
            for key in keys where remembered[key]?.report.verdict == .incomplete { remembered[key] = nil }
        } else {
            return
        }
        defaults.set(try? JSONEncoder().encode(remembered), forKey: Self.rememberedKey)
    }

    /// Checked and found incomplete: failover to another Usenet stream passes it by.
    func isIncomplete(_ stream: NuvioStream) -> Bool {
        guard case .checked(let report)? = state(for: stream) else { return false }
        return report.verdict == .incomplete
    }

    /// Checks the Usenet ones among `streams`, in order, but not streams checked within
    /// `resultLifetime` or remembered incomplete.
    func check(_ streams: [NuvioStream]) {
        var seen = Set<URL>()
        for stream in streams {
            guard let spec = Self.spec(for: stream), seen.insert(spec.nzbURL).inserted else { continue }
            let url = spec.nzbURL
            if let titleKey = Self.titleKey(stream, spec: spec) { titleKeys[Self.memoryKey(spec)] = titleKey }
            if states[url]?.isPending == true { continue }
            if case .checked? = states[url], let at = checkedAt[url],
               Date().timeIntervalSince(at) < Self.resultLifetime { continue }
            // Remembered incomplete or played on these servers: nothing to ask.
            if states[url] == nil, rememberedEntry(spec) != nil { continue }
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
                if case .failed(let message) = state {
                    usenetLog.error("usenet: check failed: \(message, privacy: .public)")
                }
                self.finish(spec, state)
            }
        }
        if running == 0, queue.isEmpty, !pools.isEmpty { schedulePoolShutdown() }
    }

    private func finish(_ spec: UsenetStreamSpec, _ state: State) {
        let url = spec.nzbURL
        states[url] = state
        if case .checked(var report) = state {
            // What playing it showed outweighs a sample: a check doesn't clear it.
            if report.playbackProblem == nil,
               let problem = rememberedEntry(spec)?.report.playbackProblem {
                report.playbackProblem = problem
                states[url] = .checked(report)
            }
            checkedAt[url] = Date()
            remember(spec, report)
        }
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
        usenetLog.notice("usenet: check \(name, privacy: .public) — \(report.verdict.rawValue, privacy: .public), \(report.missing)/\(report.checked) sampled articles missing (\(report.downloaded) downloaded), NZB gaps \(report.nzbGaps), missing volumes \(report.missingVolumes); NZB \(Self.milliseconds(loaded - started)) ms, servers \(Self.milliseconds(done - loaded)) ms")
        return report
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
