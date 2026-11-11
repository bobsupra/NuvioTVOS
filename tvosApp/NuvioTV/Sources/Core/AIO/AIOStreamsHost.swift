import Foundation
import Darwin
import Security
import os

/// The original AIOStreams running inside Nuvio on Apple TV, in Node.js 24
/// built for tvOS (nodejs-mobile, the `NodeMobile` package). The app carries
/// `NodeMobile.framework` and the installer
/// (`AIOInstaller`: bootstrap.mjs, image-install.mjs, nuvio-main.mjs, shims);
/// AIOStreams itself comes from its official Docker image (or another source
/// set in the sheet): the first start installs the newest version, Update
/// installs a newer one for the next start, and the previous one stays, to go
/// back to (automatically when a new version never got ready). `nuvio-main.mjs`
/// starts AIOStreams on 127.0.0.1 with a proxy for its configuration page on
/// the network, and a port of Nuvio's own (127.0.0.1 only) for the versions.
///
/// Node can be started once per app run. When the configuration page creates,
/// loads or saves a configuration, `nuvio-main.mjs` writes its addon address
/// to the state file and a backup of it to the backup file. Nuvio remembers
/// the address (so the addon is back after a restart), keeps the backup in the
/// Keychain and, as tvOS keeps AIOStreams' database in Caches and may clear
/// it, restores the configuration from the backup when AIOStreams no longer
/// has it. The addon is added on this Apple TV only: its address is never
/// synced (with Save to Nuvio Account the configuration is: `AIOSettingsSync`).
///
/// After each start, and after a long time in the background, one stream
/// request warms AIOStreams up, so the first real search is not the slow one
/// (unless a real search came first: then it is not needed and would only
/// slow that one down). A stream search while AIOStreams is still starting
/// waits for its addon (`startingAddonURL` / `waitForAddon`) instead of
/// leaving it out; Nuvio reads the state file every 0.25 s while AIOStreams
/// starts, so the search goes out as soon as AIOStreams answers. The times of
/// the start (`startupProfile`) are in the sheet and the log.
///
/// Everything Node.js prints goes straight to a log file, and a crash or an
/// exit() leaves a note with the native stack in it, so the next app run can
/// show how the last one ended (there is no other way to see a crash on an
/// Apple TV without a Mac).
@MainActor
final class AIOStreamsHost: ObservableObject {
    static let shared = AIOStreamsHost()

    nonisolated static let aioPort = 8770
    nonisolated static let lanPort = 8767
    nonisolated static let autoStartKey = "aio.experiment.autoStart"
    nonisolated static let addonKey = "aio.experiment.addonEnabled"
    private nonisolated static let secretKey = "aio.experiment.secret"
    private nonisolated static let runRecordKey = "aio.experiment.lastRun"
    private nonisolated static let manifestKey = "aio.experiment.manifest"
    nonisolated static let detailedLogKey = "aio.experiment.detailedLog"
    private nonisolated static let backupDefaultsKey = "aio.experiment.backup"
    nonisolated static let sourceKey = "aio.experiment.source"
    private nonisolated static let usePreviousKey = "aio.experiment.usePrevious"
    private nonisolated static let versionKey = "aio.experiment.version"
    nonisolated static let animeRequestKey = "aio.experiment.animeRequest"
    /// AIOStreams' official image.
    nonisolated static let defaultSource = "ghcr.io/viren070/aiostreams"
    /// Nuvio's own port in nuvio-main.mjs (versions), 127.0.0.1 only.
    nonisolated static let controlPort = 8771
    private let controlToken = UUID().uuidString
    /// The movie the warm-up asks for (The Matrix).
    private nonisolated static let warmUpID = "tt0133093"

    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case notAnswering
        case exited(Int32)
        case unavailable(String)
    }

    enum RunKind: String {
        case aio
        case nodeTest = "node-test"
    }

    /// Which id the AIOStreams addon is asked by for an AniList title (with
    /// the AniList integration). AIOStreams passes an id on unchanged, and
    /// only to its add-ons that take it: by its AniList id only the anilist
    /// add-ons answer (NimeToDex, TorBox Search, SeaDex…), by the converted
    /// IMDb / Kitsu id all the others. Both: two requests at once, merged.
    enum AnimeRequest: String, CaseIterable {
        case aniList = "anilist"
        case converted
        case both

        var label: String {
            switch self {
            case .aniList: return "AniList ID"
            case .converted: return "Converted ID"
            case .both: return "Both"
            }
        }

        var explanation: String {
            switch self {
            case .aniList: return "Only AIOStreams' add-ons that take AniList ids answer"
            case .converted: return "Asked by the IMDb or Kitsu id: the add-ons that take AniList ids are left out"
            case .both: return "Asked by both at once, the streams merged: every add-on answers"
            }
        }
    }

    /// How the previous app run ended, from its log file.
    struct PreviousRun {
        let summary: String
        let unexpected: Bool
        let date: Date?
        let lines: [String]
    }

    @Published private(set) var phase = Phase.stopped
    @Published private(set) var runKind: RunKind?
    @Published private(set) var packageVersion = ""
    @Published private(set) var startupSeconds: Double?
    @Published private(set) var nodeMemoryMB: Int?
    @Published private(set) var appMemoryMB: Int?
    @Published private(set) var manifestURL: String?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var previousRun: PreviousRun?
    @Published private(set) var notice: String?
    @Published private(set) var lastWarmUp: String?
    @Published private(set) var hasBackup = false
    /// AIOStreams in the Nuvio account (Save to Nuvio Account, `AIOSettingsSync`).
    @Published private(set) var syncToAccount: Bool
    @Published private(set) var autoStart: Bool
    @Published private(set) var addonEnabled: Bool
    @Published private(set) var detailedLog: Bool
    /// Where AIOStreams comes from: an image or a package address.
    @Published private(set) var source: String
    @Published private(set) var installProgress: String?
    @Published private(set) var previousVersion: String?
    @Published private(set) var pendingVersion: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateStatus: String?
    @Published private(set) var updating = false
    @Published private(set) var usePreviousAtNextStart = false
    /// When what happened in this start, in seconds after Nuvio opened.
    @Published private(set) var startupProfile: String?
    @Published private(set) var animeRequest: AnimeRequest
    /// The last search by both ids: how long each took, how many streams.
    @Published private(set) var lastAnimeSearch: String?

    private var stateTimer: Timer?
    /// From Nuvio opening to Node.js being started.
    private var launchOffset: TimeInterval?
    /// When Nuvio saw AIOStreams answering, after Node.js was started.
    private var noticedSeconds: TimeInterval?
    private var startupMarks: [String: Any] = [:]
    private var logTimer: Timer?
    private var logVisible = false
    private var started = false
    private var startDate: Date?
    private var markedReady = false
    private var lastStartUnfinished = false
    /// The remembered configuration exists in AIOStreams (checked after each start).
    private var configurationVerified = false
    private var checkingConfiguration = false
    private var warmingUp = false
    private var backgroundSince: Date?
    /// The addon address last seen in the state file (the page's doing).
    private var lastStateManifest: String?

    private init() {
        autoStart = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        addonEnabled = UserDefaults.standard.object(forKey: Self.addonKey) as? Bool ?? true
        detailedLog = UserDefaults.standard.bool(forKey: Self.detailedLogKey)
        manifestURL = UserDefaults.standard.string(forKey: Self.manifestKey)
        source = UserDefaults.standard.string(forKey: Self.sourceKey) ?? Self.defaultSource
        packageVersion = UserDefaults.standard.string(forKey: Self.versionKey) ?? ""
        usePreviousAtNextStart = UserDefaults.standard.bool(forKey: Self.usePreviousKey)
        animeRequest = Self.animeRequestSetting
        hasBackup = Self.loadBackup() != nil
        syncToAccount = AIOSettingsSync.syncChoice() ?? false
        loadPreviousRun()
        let center = NotificationCenter.default
        _ = center.addObserver(forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil) { _ in
            Self.note("memory warning · \(Self.memoryDescription())")
        }
        _ = center.addObserver(forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"), object: nil, queue: nil) { _ in
            Task { @MainActor in AIOStreamsHost.shared.backgroundSince = Date() }
        }
        _ = center.addObserver(forName: Notification.Name("UIApplicationWillEnterForegroundNotification"), object: nil, queue: nil) { _ in
            Task { @MainActor in AIOStreamsHost.shared.enteredForeground() }
        }
    }

    // MARK: - The addon, for CatalogRepository

    private nonisolated(unsafe) static var currentAddonURL: URL?
    /// AIOStreams runs (or starts) with its addon on.
    private nonisolated(unsafe) static var servingAddon = false
    /// While AIOStreams starts (or its configuration is checked or restored):
    /// the address its addon will most likely have.
    private nonisolated(unsafe) static var pendingAddonURL: URL?
    private nonisolated static let addonLock = NSLock()

    /// AIOStreams runs (or starts) with its addon on: plugins set "Through AIOStreams"
    /// come through it (``PluginAIOBridge``).
    nonisolated static var isServingAddon: Bool {
        addonLock.lock()
        defer { addonLock.unlock() }
        return servingAddon
    }

    /// The AIOStreams addon while it runs and is turned on.
    nonisolated static var addonManifestURLs: [URL] {
        addonLock.lock()
        defer { addonLock.unlock() }
        return currentAddonURL.map { [$0] } ?? []
    }

    /// For `CatalogRepository.configuredStreamAddonManifestURLs`: the addon,
    /// unless the same configuration was also added by hand (its address on
    /// the network) — then once is enough.
    nonisolated static func aioAddonURLs(besides installed: [URL]) -> [URL] {
        addonManifestURLs.filter { url in
            guard let uuid = uuid(fromManifest: url.absoluteString) else { return true }
            return !installed.contains { $0.absoluteString.contains("/stremio/\(uuid)/") }
        }
    }

    /// Posted when the addon appears, changes or goes away: Home loads its
    /// catalogs again (NuvioSyncManager), as AIOStreams starts after Nuvio.
    nonisolated static let addonChangedNotification = Notification.Name("nuvio.aio.experiment.addonChanged")

    private func publishAddon() {
        let url = (phase == .running && addonEnabled && configurationVerified) ? manifestURL.flatMap(URL.init(string:)) : nil
        let coming = url == nil && addonEnabled && (phase == .starting || (phase == .running && checkingConfiguration))
        let pending = coming ? manifestURL.flatMap(URL.init(string:)) : nil
        let serving = addonEnabled && (phase == .starting || phase == .running)
        Self.addonLock.lock()
        let changed = Self.currentAddonURL != url || Self.servingAddon != serving
        Self.currentAddonURL = url
        Self.pendingAddonURL = pending
        Self.servingAddon = serving
        Self.addonLock.unlock()
        if changed {
            NotificationCenter.default.post(name: Self.addonChangedNotification, object: nil)
        }
    }

    /// For `StreamsRepository`: while AIOStreams starts, its addon's likely
    /// address, so a stream search can wait for it instead of leaving it out.
    nonisolated static func startingAddonURL(besides installed: [URL]) -> URL? {
        addonLock.lock()
        let pending = pendingAddonURL
        addonLock.unlock()
        guard let pending, let uuid = uuid(fromManifest: pending.absoluteString),
              !installed.contains(where: { $0.absoluteString.contains("/stremio/\(uuid)/") }) else { return nil }
        return pending
    }

    /// The addon once AIOStreams has started and checked its configuration;
    /// nil when it does not come within `seconds` or AIOStreams stopped.
    nonisolated static func waitForAddon(seconds: TimeInterval) async -> URL? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !Task.isCancelled {
            addonLock.lock()
            let current = currentAddonURL
            let pending = pendingAddonURL
            addonLock.unlock()
            if let current { return current }
            if pending == nil { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: - Anime searches (AniList titles)

    nonisolated static var animeRequestSetting: AnimeRequest {
        UserDefaults.standard.string(forKey: animeRequestKey).flatMap(AnimeRequest.init(rawValue:)) ?? .both
    }

    func setAnimeRequest(_ request: AnimeRequest) {
        animeRequest = request
        UserDefaults.standard.set(request.rawValue, forKey: Self.animeRequestKey)
    }

    /// The next choice, for the row in the sheet.
    func cycleAnimeRequest() {
        let all = AnimeRequest.allCases
        let index = all.firstIndex(of: animeRequest) ?? 0
        setAnimeRequest(all[(index + 1) % all.count])
    }

    /// Is `manifestURL` the addon of the AIOStreams running here (its own
    /// address, or the configuration page's one added by hand)?
    nonisolated static func isAIOAddon(_ manifestURL: URL) -> Bool {
        guard let port = manifestURL.port, port == aioPort || port == lanPort,
              manifestURL.path.contains("/stremio/") else { return false }
        if manifestURL.host == "127.0.0.1" { return true }
        return manifestURL.host == Self.localIPv4Address()
    }

    /// The ids the AIOStreams addon is asked by for `videoId`; [] = none it
    /// takes. An AniList title (`anilist:…`) goes by the setting, with
    /// `alternatives` — the other ids it could be asked by, best first (the
    /// AniList integration's conversion) — of which an IMDb id comes first.
    /// Anything else: `videoId` alone. `supports`: whether AIOStreams'
    /// manifest takes an id.
    nonisolated static func requestIDs(
        videoId: String,
        alternatives: [String],
        request: AnimeRequest = animeRequestSetting,
        supports: (String) -> Bool
    ) -> [String] {
        let own = supports(videoId) ? videoId : nil
        guard videoId.hasPrefix("anilist:") else { return own.map { [$0] } ?? [] }
        let usable = alternatives.filter { $0 != videoId && supports($0) }
        let converted = usable.first { $0.hasPrefix("tt") } ?? usable.first
        switch request {
        case .aniList: return [own ?? converted].compactMap { $0 }
        case .converted: return [converted ?? own].compactMap { $0 }
        case .both: return [own, converted].compactMap { $0 }
        }
    }

    /// A search by both ids: in the log and the sheet.
    func noteAnimeSearch(_ text: String) {
        lastAnimeSearch = text
        Self.note("search by both ids: \(text)")
    }

    /// This Apple TV's address in the home network (Wi-Fi or Ethernet).
    nonisolated static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var next = interfaces
        while let item = next {
            defer { next = item.pointee.ifa_next }
            let info = item.pointee
            guard let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  info.ifa_flags & UInt32(IFF_UP) != 0,
                  info.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  String(cString: info.ifa_name).hasPrefix("en") else { continue }
            let result: String? = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ip = pointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let result { return result }
        }
        return nil
    }

    nonisolated static func uuid(fromManifest manifest: String) -> String? {
        guard let range = manifest.range(of: "/stremio/") else { return nil }
        let rest = manifest[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let uuid = String(rest[..<slash])
        return uuid.isEmpty ? nil : uuid.removingPercentEncoding ?? uuid
    }

    // MARK: - Settings

    func setAutoStart(_ enabled: Bool) {
        autoStart = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoStartKey)
    }

    func setAddonEnabled(_ enabled: Bool) {
        addonEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.addonKey)
        publishAddon()
        if enabled { Task { await warmUp() } }
    }

    /// Every request in AIOStreams' log (info) instead of warnings and errors
    /// only; from the next start.
    func setDetailedLog(_ enabled: Bool) {
        detailedLog = enabled
        UserDefaults.standard.set(enabled, forKey: Self.detailedLogKey)
    }

    /// AIOStreams' settings here and its configuration (with the password) in
    /// this profile of the Nuvio account; off removes them from the account.
    func setSyncToAccount(_ enabled: Bool) {
        syncToAccount = enabled
        AIOSettingsSync.setSyncChoice(enabled)
    }

    /// The configuration page from a computer on the same network.
    var configurationPageURL: String? {
        guard let host = Self.localIPv4Address() else { return nil }
        return "http://\(host):\(Self.lanPort)/stremio/configure"
    }

    /// The installer in the app (AIOStreams itself is downloaded).
    nonisolated static var installer: URL? {
        guard let folder = Bundle.main.url(forResource: "AIOInstaller", withExtension: nil),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("bootstrap.mjs").path) else { return nil }
        return folder
    }

    nonisolated static var isBundled: Bool { installer != nil }

    /// Where the AIOStreams versions live (versions.json and a folder each).
    nonisolated static var versionsHome: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AIOStreams-versions", isDirectory: true)
    }

    // MARK: - Start

    func startIfWanted() {
        guard autoStart else { return }
        // A start that crashed must not crash every launch.
        if lastStartUnfinished {
            notice = "Not started automatically: the last start did not finish (see Last run). Start it here when you want to try again."
            return
        }
        start()
    }

    func start() {
        guard !started else { return }
        guard let installer = Self.installer, let home = Self.versionsHome else {
            phase = .unavailable("The AIOStreams installer is not in this build.")
            return
        }
        let bootstrap = installer.appendingPathComponent("bootstrap.mjs")
        guard let nodeStart = Self.nodeStartFunction() else {
            phase = .unavailable("Node.js (NodeMobile.framework) is not in this build.")
            return
        }
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            phase = .unavailable("No caches folder.")
            return
        }
        // The database (with the saved configuration) belongs in Application
        // Support; tvOS refuses it, then Caches (hence the backup).
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        var dataDirectory = (support ?? caches).appendingPathComponent("AIOStreams", isDirectory: true)
        if (try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)) == nil {
            dataDirectory = caches.appendingPathComponent("AIOStreams", isDirectory: true)
            try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        }
        // Earlier builds carried the package and unpacked it here.
        try? fileManager.removeItem(at: caches.appendingPathComponent("AIOStreams-package", isDirectory: true))
        let cache = caches.appendingPathComponent("AIOStreams-cache", isDirectory: true)
        let compileCache = caches.appendingPathComponent("AIOStreams-compile-cache", isDirectory: true)
        for directory in [home, cache, compileCache] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let stateFile = dataDirectory.appendingPathComponent("nuvio-state.json")
        let backupFile = dataDirectory.appendingPathComponent("nuvio-backup.json")
        try? fileManager.removeItem(at: stateFile)
        // Written whenever Nuvio comes back from the Home screen (pokeNode()).
        let wakeFile = dataDirectory.appendingPathComponent("nuvio-wake")
        if !fileManager.fileExists(atPath: wakeFile.path) {
            fileManager.createFile(atPath: wakeFile.path, contents: Data())
        }
        Self.wakeFile = wakeFile

        let host = Self.localIPv4Address() ?? "127.0.0.1"
        let environment: [String: String] = [
            "HOME": dataDirectory.path,
            "TMPDIR": NSTemporaryDirectory(),
            "NODE_ENV": "production",
            "NODE_COMPILE_CACHE": compileCache.path,
            "NODE_COMPILE_CACHE_PORTABLE": "1",
            "UV_THREADPOOL_SIZE": "4",
            "PORT": String(Self.aioPort),
            "NUVIO_LAN_PORT": String(Self.lanPort),
            "NUVIO_STATE_FILE": stateFile.path,
            "NUVIO_BACKUP_FILE": backupFile.path,
            "NUVIO_WAKE_FILE": wakeFile.path,
            "BASE_URL": "http://\(host):\(Self.lanPort)",
            "DATABASE_URI": "sqlite://" + (dataDirectory.appendingPathComponent("db.sqlite").path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""),
            "DISK_CACHE_DIR": cache.path,
            "SECRET_KEY": Self.secret(),
            "ANIME_DB_LEVEL_OF_DETAIL": "required",
            // Everything Nuvio asks comes from 127.0.0.1, one address for AIOStreams' limits
            // (15 metadata requests in 5 s, …): a busy search would answer "rate limit exceeded".
            "DISABLE_RATE_LIMITS": "true",
            // Every request in the log costs work on the TV: warnings and errors unless asked.
            "LOG_LEVEL": detailedLog ? "info" : "warn",
            // process.exit() would close Nuvio: nuvio-main.mjs turns it into a stop.
            "NUVIO_EMBEDDED": "1",
            // Versions: installed in home from the source, switched by bootstrap.mjs.
            "NUVIO_AIO_HOME": home.path,
            "NUVIO_AIO_SOURCE": source,
            "NUVIO_AIO_USE_PREVIOUS": usePreviousAtNextStart ? "1" : "0",
            "NUVIO_AIO_LAST_START_FAILED": lastStartUnfinished ? "1" : "0",
            "NUVIO_CONTROL_PORT": String(Self.controlPort),
            "NUVIO_CONTROL_TOKEN": controlToken,
            // Plugins set "Through AIOStreams", for its "Nuvio plugins" card (PluginAIOBridge).
            "NUVIO_PLUGINS_URL": PluginLoopbackServer.shared.baseURL.absoluteString + "stremio/",
        ]
        if !PluginAIOBridge.served().isEmpty { PluginLoopbackServer.shared.ensureRunning() }
        if usePreviousAtNextStart {
            usePreviousAtNextStart = false
            UserDefaults.standard.removeObject(forKey: Self.usePreviousKey)
        }
        for (name, value) in environment {
            setenv(name, value, 1)
        }
        // AIOStreams' title and year matching need TMDB: Nuvio's own key.
        if let tmdbKey = TmdbDetailsService.currentApiKey, !tmdbKey.isEmpty {
            setenv("TMDB_API_KEY", tmdbKey, 1)
        }

        launch(
            .aio,
            nodeStart: nodeStart,
            arguments: ["node", "--max-old-space-size=1024", bootstrap.path],
            stateFile: stateFile,
            backupFile: backupFile
        )
        Self.note("data: \(dataDirectory.path)")
    }

    /// Only Node.js with a short self-test, no AIOStreams: tells a crash of
    /// Node.js itself on this Apple TV from one in AIOStreams, and measures
    /// AIOStreams' way of downloading against Node.js' own.
    func testNodeOnly() {
        guard !started else { return }
        guard let nodeStart = Self.nodeStartFunction() else {
            phase = .unavailable("Node.js (NodeMobile.framework) is not in this build.")
            return
        }
        setenv("TMPDIR", NSTemporaryDirectory(), 1)
        launch(.nodeTest, nodeStart: nodeStart, arguments: ["node", "--input-type=module", "-e", Self.nodeTestScript], stateFile: nil, backupFile: nil)
    }

    private func launch(_ kind: RunKind, nodeStart: NodeStart, arguments: [String], stateFile: URL?, backupFile: URL?) {
        started = true
        runKind = kind
        let now = Date()
        startDate = now
        launchOffset = Self.processStartDate().map { now.timeIntervalSince($0) }
        // The start's times in Node.js count from here.
        setenv("NUVIO_T0_MS", String(Int64(now.timeIntervalSince1970 * 1000)), 1)
        phase = .starting
        notice = nil
        publishAddon()
        Self.saveRunRecord(kind: kind, ready: false)
        openLog()
        Self.note("start: \(kind == .aio ? "AIOStreams \(packageVersion)" : "Node.js test") · \(Self.deviceDescription()) · \(Self.memoryDescription())")
        Self.note("arguments: " + arguments.dropFirst().map { $0.count > 200 ? "<script>" : $0 }.joined(separator: " "))

        let thread = Thread {
            Self.note("Node.js thread: stack \(Thread.current.stackSize / 1_048_576) MB · calling node_start")
            let status = Self.run(nodeStart, arguments: arguments)
            Self.note("Node.js exited with code \(status)")
            Task { @MainActor in
                let shared = AIOStreamsHost.shared
                shared.phase = .exited(status)
                shared.refreshLog()
                shared.publishAddon()
            }
        }
        thread.name = "Node.js (AIOStreams)"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()

        scheduleStateTimer(every: 0.25, stateFile: stateFile, backupFile: backupFile)
        if logVisible { startLogTimer() }
    }

    /// The state file every 0.25 s while AIOStreams starts (searches wait for
    /// it), then every 5 s.
    private func scheduleStateTimer(every seconds: TimeInterval, stateFile: URL?, backupFile: URL?) {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            Task { @MainActor in
                let shared = AIOStreamsHost.shared
                if let stateFile { shared.readState(stateFile, backupFile: backupFile) }
                if shared.runKind == .nodeTest { shared.refreshLog() }
            }
        }
    }

    // MARK: - State

    private func readState(_ file: URL, backupFile: URL?) {
        appMemoryMB = Self.appFootprintMB()
        if let backupFile { takeBackup(from: backupFile) }
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let wasStarting = phase == .starting
        if let status = state["status"] as? String {
            switch (status, phase) {
            case ("running", .starting): phase = .running
            case ("not answering", .starting): phase = .notAnswering
            case ("failed", _), ("stopped", _):
                phase = .unavailable("AIOStreams stopped: \(state["error"] as? String ?? "see the log") — restart Nuvio to try again")
            default: break
            }
        }
        installProgress = state["status"] as? String == "installing" ? state["installing"] as? String : nil
        if let version = state["version"] as? String, !version.isEmpty, version != packageVersion {
            packageVersion = version
            UserDefaults.standard.set(version, forKey: Self.versionKey)
        }
        if let seconds = state["startupSeconds"] as? Double { startupSeconds = seconds }
        if let rss = state["rssMB"] as? Int { nodeMemoryMB = rss }
        if phase == .running, wasStarting, let startDate {
            noticedSeconds = Date().timeIntervalSince(startDate)
            Self.note(String(format: "Nuvio saw AIOStreams answering %.2f s after starting Node.js", noticedSeconds ?? 0))
        }
        if let marks = state["startup"] as? [String: Any] {
            startupMarks = marks
        }
        composeStartupProfile()
        if let manifest = state["manifest"] as? String, manifest != lastStateManifest {
            // Created or loaded on the page just now: it exists.
            lastStateManifest = manifest
            manifestURL = manifest
            UserDefaults.standard.set(manifest, forKey: Self.manifestKey)
            configurationVerified = true
            notice = nil
            publishAddon()
            Task { await warmUp() }
        }
        if phase == .running, !markedReady {
            markedReady = true
            Self.saveRunRecord(kind: .aio, ready: true)
            Self.note("ready · \(Self.memoryDescription())")
        }
        if wasStarting, phase != .starting {
            scheduleStateTimer(every: 5, stateFile: file, backupFile: backupFile)
            if phase == .running {
                // The remembered addon at once; checked right after (and taken
                // back, or restored, if AIOStreams no longer has it).
                if manifestURL != nil { configurationVerified = true }
                Task { await checkConfiguration() }
                Task { await refreshVersions() }
            }
        }
        publishAddon()
    }

    private nonisolated static func saveRunRecord(kind: RunKind, ready: Bool) {
        UserDefaults.standard.set(["kind": kind.rawValue, "ready": ready, "date": Date()], forKey: runRecordKey)
    }

    /// "Start, seconds after Nuvio opened: …" from the times Node.js reports
    /// (counted from when Nuvio started it) and Nuvio's own.
    private func composeStartupProfile() {
        guard runKind == .aio, !startupMarks.isEmpty || noticedSeconds != nil else { return }
        let offset = launchOffset ?? 0
        func value(_ key: String) -> Double? { (startupMarks[key] as? NSNumber)?.doubleValue }
        func at(_ seconds: Double) -> String { String(format: "%.1f", seconds + offset) }
        var parts: [String] = []
        if let launchOffset { parts.append("Node.js started \(String(format: "%.1f", launchOffset))") }
        if let loaded = value("loaded") { parts.append("AIOStreams loaded \(at(loaded))") }
        if let ready = value("ready") { parts.append("answering \(at(ready))") }
        if let noticedSeconds { parts.append("Nuvio saw it \(at(noticedSeconds))") }
        if let asked = value("firstAsked") {
            var first = "first streams asked \(at(asked))"
            if let answered = value("firstAnswered") { first += ", there \(at(answered))" }
            parts.append(first)
        }
        if let held = (startupMarks["held"] as? NSNumber)?.intValue, held > 0 {
            parts.append(value("heldSeconds").map { "\(held) data refreshes after the start (\(String(format: "%.1f", $0)) s)" }
                ?? "\(held) data refreshes held until after the start")
        }
        guard !parts.isEmpty else { return }
        startupProfile = (launchOffset == nil ? "Start, seconds after Node.js started: " : "Start, seconds after Nuvio opened: ")
            + parts.joined(separator: " · ")
    }

    /// When this app process started (Nuvio opened), from the kernel.
    private nonisolated static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        let age = Date().timeIntervalSince(date)
        return age >= 0 && age < 30 * 86_400 ? date : nil
    }

    // MARK: - Configuration: check, backup, restore

    /// After a start: does AIOStreams still have the remembered configuration?
    /// If not, it comes back from the backup (as a new configuration with the
    /// same settings and password), or Nuvio says so.
    func checkConfiguration() async {
        guard phase == .running, !checkingConfiguration else { return }
        // A newer configuration from the Nuvio account comes first.
        if UserDefaults.standard.bool(forKey: AIOSettingsSync.pendingBackupKey), await applySyncedBackup() {
            return
        }
        checkingConfiguration = true
        defer {
            checkingConfiguration = false
            publishAddon()
        }
        if let manifest = manifestURL, let uuid = Self.uuid(fromManifest: manifest) {
            switch await Self.userExists(uuid) {
            case .some(false):
                Self.note("configuration \(uuid.prefix(8))… is no longer in AIOStreams")
                // Searches wait for the restored one instead.
                configurationVerified = false
                publishAddon()
            default:
                configurationVerified = true
                publishAddon()
                await warmUp(unlessSearchSince: startDate)
                return
            }
        }
        guard let backup = Self.loadBackup(),
              let config = backup["config"],
              let password = backup["password"] as? String else {
            if manifestURL != nil {
                notice = "AIOStreams no longer has your configuration (tvOS may have cleared its storage). Open the configuration page and create or load it again."
                forgetConfiguration()
            }
            return
        }
        guard let restored = await Self.createConfiguration(config: config, password: password) else {
            notice = "Your configuration could not be restored from the backup (see the log). Open the configuration page and create or load it again."
            forgetConfiguration()
            return
        }
        Self.note("configuration restored from the backup as \(restored.uuid.prefix(8))…")
        var updated = backup
        updated["uuid"] = restored.uuid
        if let data = try? JSONSerialization.data(withJSONObject: updated) { Self.saveBackup(data) }
        manifestURL = restored.manifest
        UserDefaults.standard.set(restored.manifest, forKey: Self.manifestKey)
        configurationVerified = true
        notice = nil
        publishAddon()
        await warmUp(unlessSearchSince: startDate)
    }

    private func forgetConfiguration() {
        manifestURL = nil
        configurationVerified = false
        UserDefaults.standard.removeObject(forKey: Self.manifestKey)
        publishAddon()
    }

    /// The backup nuvio-main.mjs wrote moves to the Keychain.
    private func takeBackup(from file: URL) {
        guard let data = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        if Self.saveBackup(data) {
            hasBackup = true
            // The account sync notices it (when this Apple TV keeps AIOStreams there).
            AIOSettingsSync.noteNewBackup()
        }
    }

    // MARK: - From the Nuvio account (AIOSettingsSync)

    /// An account pull brought AIOStreams' settings or a newer configuration.
    func syncedFromAccount(_ imported: AIOSettingsSync.Imported) {
        let defaults = UserDefaults.standard
        syncToAccount = AIOSettingsSync.syncChoice() ?? false
        autoStart = defaults.bool(forKey: Self.autoStartKey)
        addonEnabled = defaults.object(forKey: Self.addonKey) as? Bool ?? true
        detailedLog = defaults.bool(forKey: Self.detailedLogKey)
        source = defaults.string(forKey: Self.sourceKey) ?? Self.defaultSource
        animeRequest = Self.animeRequestSetting
        hasBackup = Self.loadBackup() != nil
        if imported.settings { Self.note("settings from the Nuvio account") }
        publishAddon()
        if imported.backup {
            Self.note("a newer configuration in the Nuvio account")
            Task { await applySyncedBackup() }
        }
        // Start with Nuvio came from the account (a reinstall, another Apple TV): now.
        if phase == .stopped { startIfWanted() }
    }

    /// The configuration from the account into AIOStreams: into the one here
    /// when it has the same password (the addon keeps its address), else as a
    /// new configuration, whose addon takes the old one's place. Runs once
    /// AIOStreams answers (`checkConfiguration` after a start); true when the
    /// configuration is in.
    @discardableResult
    func applySyncedBackup() async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AIOSettingsSync.pendingBackupKey), phase == .running, !checkingConfiguration else { return false }
        defaults.removeObject(forKey: AIOSettingsSync.pendingBackupKey)
        guard let backup = Self.loadBackup(), let config = backup["config"],
              let password = backup["password"] as? String else { return false }
        checkingConfiguration = true
        publishAddon()
        defer {
            checkingConfiguration = false
            publishAddon()
        }
        if let uuid = backup["uuid"] as? String, let manifest = manifestURL, Self.uuid(fromManifest: manifest) == uuid,
           await Self.updateConfiguration(uuid: uuid, password: password, config: config) {
            Self.note("configuration \(uuid.prefix(8))… updated from the Nuvio account")
        } else {
            guard let created = await Self.createConfiguration(config: config, password: password) else {
                notice = "The configuration from your Nuvio account could not be loaded into AIOStreams (see the log)."
                return false
            }
            Self.note("configuration from the Nuvio account loaded as \(created.uuid.prefix(8))…")
            var updated = backup
            updated["uuid"] = created.uuid
            if let data = try? JSONSerialization.data(withJSONObject: updated) { Self.saveBackup(data) }
            manifestURL = created.manifest
            defaults.set(created.manifest, forKey: Self.manifestKey)
        }
        configurationVerified = true
        notice = nil
        publishAddon()
        await warmUp(unlessSearchSince: startDate)
        return true
    }

    /// Changes into an existing configuration (PUT, as the page saves them).
    private nonisolated static func updateConfiguration(uuid: String, password: String, config: Any) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(aioPort)/api/v1/user"),
              let body = try? JSONSerialization.data(withJSONObject: ["config": config]) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(uuid):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 60
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            note("account configuration: AIOStreams did not answer")
            return false
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            note("account configuration: HTTP \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return (200..<300).contains(status)
    }

    /// true / false, or nil when AIOStreams did not answer.
    private nonisolated static func userExists(_ uuid: String) async -> Bool? {
        var components = URLComponents(string: "http://127.0.0.1:\(aioPort)/api/v1/user")
        components?.queryItems = [URLQueryItem(name: "uuid", value: uuid)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 200 { return true }
        return (400..<500).contains(status) ? false : nil
    }

    private nonisolated static func createConfiguration(config: Any, password: String) async -> (uuid: String, manifest: String)? {
        guard let url = URL(string: "http://127.0.0.1:\(aioPort)/api/v1/user"),
              let body = try? JSONSerialization.data(withJSONObject: ["config": config, "password": password]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            note("restore: AIOStreams did not answer")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = object["data"] as? [String: Any],
              let uuid = answer["uuid"] as? String,
              let encrypted = answer["encryptedPassword"] as? String else {
            note("restore: HTTP \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
            return nil
        }
        // As encodeURIComponent in nuvio-main.mjs.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let manifest = "http://127.0.0.1:\(aioPort)/stremio/\(uuid.addingPercentEncoding(withAllowedCharacters: unreserved) ?? uuid)/\(encrypted.addingPercentEncoding(withAllowedCharacters: unreserved) ?? encrypted)/manifest.json"
        return (uuid, manifest)
    }

    // The backup (configuration and its password) lives in the Keychain; a
    // build without Keychain access (unsigned simulator tests) keeps it in
    // the user defaults instead.
    private nonisolated static var backupQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "nuvio.aio.experiment",
            kSecAttrAccount as String: "configuration",
        ]
    }

    @discardableResult
    nonisolated static func saveBackup(_ data: Data) -> Bool {
        let stored = (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
        SecItemDelete(backupQuery as CFDictionary)
        var item = backupQuery
        item[kSecValueData as String] = stored
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: backupDefaultsKey)
            return true
        }
        UserDefaults.standard.set(stored, forKey: backupDefaultsKey)
        return true
    }

    nonisolated static func loadBackup() -> [String: Any]? {
        var query = backupQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        var stored: Data?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess {
            stored = item as? Data
        }
        if stored == nil { stored = UserDefaults.standard.data(forKey: backupDefaultsKey) }
        guard let stored else { return nil }
        let data = (try? (stored as NSData).decompressed(using: .zlib) as Data) ?? stored
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Versions (nuvio-main.mjs, Nuvio's own port)

    private func control(_ method: String, _ path: String, timeout: TimeInterval = 30) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(Self.controlPort)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(controlToken, forHTTPHeaderField: "x-nuvio-token")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func refreshVersions() async {
        guard phase == .running, let versions = await control("GET", "/versions") else { return }
        if let current = versions["current"] as? String, !current.isEmpty, current != packageVersion {
            packageVersion = current
            UserDefaults.standard.set(current, forKey: Self.versionKey)
        }
        previousVersion = versions["previous"] as? String
        pendingVersion = versions["pending"] as? String
    }

    /// The newest version the source offers.
    func checkForUpdates() async {
        guard phase == .running else {
            updateStatus = "Start AIOStreams first"
            return
        }
        updateStatus = "Checking…"
        guard let answer = await control("POST", "/check", timeout: 60) else {
            updateStatus = "Could not check (see the log)"
            return
        }
        if let error = answer["error"] as? String {
            updateStatus = "Could not check: \(error)"
            return
        }
        latestVersion = answer["latest"] as? String
        if let latest = latestVersion, latest == packageVersion {
            updateStatus = "\(latest) is the newest"
        } else if let latest = latestVersion {
            updateStatus = pendingVersion == latest ? "\(latest) is installed — restart Nuvio to use it" : "\(latest) is available"
        } else {
            updateStatus = "The source does not say its version"
        }
    }

    /// Installs the newest version for the next start; AIOStreams keeps running.
    func update() async {
        guard phase == .running, !updating else { return }
        updating = true
        defer { updating = false }
        guard await control("POST", "/update") != nil else {
            updateStatus = "Could not start the update (see the log)"
            return
        }
        for _ in 0..<1200 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let state = await control("GET", "/update") else { continue }
            switch state["state"] as? String {
            case "running":
                updateStatus = state["progress"] as? String ?? "Updating…"
            case "done":
                let version = state["version"] as? String ?? ""
                if state["upToDate"] as? Bool == true {
                    updateStatus = "\(version) is the newest"
                } else {
                    pendingVersion = version
                    updateStatus = "\(version) is installed — restart Nuvio to use it"
                }
                await refreshVersions()
                return
            default:
                updateStatus = "Update failed: \(state["error"] as? String ?? "see the log")"
                return
            }
        }
        updateStatus = "The update did not finish in 20 minutes (see the log)"
    }

    /// The previous version from the next start of Nuvio.
    func usePreviousVersion() {
        usePreviousAtNextStart = true
        UserDefaults.standard.set(true, forKey: Self.usePreviousKey)
        updateStatus = "\(previousVersion ?? "The previous version") starts with the next start of Nuvio"
    }

    /// From the next start (and for Update).
    func setSource(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        source = trimmed.isEmpty ? Self.defaultSource : trimmed
        UserDefaults.standard.set(source, forKey: Self.sourceKey)
        updateStatus = "Source changed — it applies from the next start of Nuvio"
    }

    func resetSource() {
        setSource(Self.defaultSource)
    }

    // MARK: - Warm-up

    /// One stream request through the whole of AIOStreams (its addons, debrid,
    /// filters) and its connections, so the first real search is quick.
    /// `unlessSearchSince`: right after AIOStreams started, or Nuvio came
    /// back from the Home screen, when the user may already be searching. A
    /// search warms AIOStreams up itself, and a warm-up next to it would only
    /// slow it down, so the warm-up waits a moment and is left out when a
    /// search came since then (nuvio-main.mjs notes when).
    func warmUp(unlessSearchSince since: Date? = nil) async {
        guard phase == .running, addonEnabled, configurationVerified, !warmingUp, manifestURL != nil else { return }
        warmingUp = true
        defer { warmingUp = false }
        if let since {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let last = (await control("GET", "/activity"))?["lastStreamAt"] as? Double,
               last >= since.timeIntervalSince1970 * 1000 {
                lastWarmUp = "not needed, a search came first"
                Self.note("warm-up: not needed, a search came first")
                return
            }
        }
        guard phase == .running, let manifest = manifestURL,
              let url = URL(string: manifest.replacingOccurrences(of: "/manifest.json", with: "/stream/movie/\(Self.warmUpID).json")) else { return }
        let begin = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        // Not counted as a search (nuvio-main.mjs).
        request.setValue("1", forHTTPHeaderField: "x-nuvio-warmup")
        let result: String
        if let (data, response) = try? await URLSession.shared.data(for: request) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let streams = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["streams"] as? [Any]
            result = status == 200
                ? "\(streams?.count ?? 0) streams in \(String(format: "%.1f", Date().timeIntervalSince(begin))) s"
                : "HTTP \(status) after \(String(format: "%.1f", Date().timeIntervalSince(begin))) s"
        } else {
            result = "no answer after \(String(format: "%.1f", Date().timeIntervalSince(begin))) s"
        }
        lastWarmUp = result
        Self.note("warm-up: \(result)")
    }

    /// Back from the Home screen. tvOS takes a suspended app's ports away,
    /// even after a few seconds, so Nuvio can't tell Node.js through them:
    /// it writes to a file Node.js watches (``pokeNode()``), and Node.js checks
    /// its port and listens again within milliseconds. Until AIOStreams answers again
    /// (at most ``wakingSeconds``), requests to it wait (``waitWhileWaking(for:)``)
    /// instead of failing. After a minute or more away it is warmed up again:
    /// its connections to add-ons and debrid have gone stale.
    private func enteredForeground() {
        defer { backgroundSince = nil }
        guard runKind == .aio, phase == .running else { return }
        // Every time: Node.js checks its ports at once (nuvio-main.mjs).
        Self.pokeNode()
        guard let since = backgroundSince else { return }
        let away = Date().timeIntervalSince(since)
        let back = Date()
        Self.setWaking(until: back.addingTimeInterval(Self.wakingSeconds))
        Task {
            // The plugins' server too, when AIOStreams gets plugins from it.
            if !PluginAIOBridge.served().isEmpty { Task { await Self.checkPluginServer() } }
            var answers = await Self.answers(timeout: 1)
            while !answers, Date().timeIntervalSince(back) < Self.wakingSeconds {
                try? await Task.sleep(nanoseconds: 200_000_000)
                answers = await Self.answers(timeout: 1)
            }
            Self.setWaking(until: nil)
            let after = Date().timeIntervalSince(back)
            Self.note(String(
                format: "back after %.0f s on the Home screen: AIOStreams %@",
                away,
                answers ? String(format: "answers (%.1f s after coming back)", after) : "does not answer"
            ))
            if answers, away > 60 { await warmUp(unlessSearchSince: back) }
        }
    }

    /// The plugins' server after a sleep: started again when it no longer answers
    /// (tvOS may have taken its port away too).
    private static func checkPluginServer() async {
        let server = PluginLoopbackServer.shared
        server.ensureRunning()
        guard let url = URL(string: server.baseURL.absoluteString + "stremio/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        if let (_, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 { return }
        Self.note("back from the Home screen: the plugins' server listens again")
        server.stop()
        server.ensureRunning()
    }

    private nonisolated(unsafe) static var wakeFile: URL?

    /// Wakes Node.js up: a write to `NUVIO_WAKE_FILE`, in place, so the watch
    /// on it (kqueue) stays.
    private static func pokeNode() {
        guard let file = wakeFile, let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: Data(String(Date().timeIntervalSince1970).utf8))
    }

    /// How long requests to AIOStreams wait for it after Nuvio comes back.
    nonisolated static let wakingSeconds: TimeInterval = 8
    private nonisolated(unsafe) static var wakingUntil: Date?

    private nonisolated static func setWaking(until date: Date?) {
        addonLock.lock()
        wakingUntil = date
        addonLock.unlock()
    }

    /// For requests to the AIOStreams addon (streams, subtitles, its manifest):
    /// right after Nuvio came back from the Home screen, wait until AIOStreams
    /// listens again. Returns at once otherwise.
    nonisolated static func waitWhileWaking(for url: URL) async {
        guard isAIOAddon(url) else { return }
        while !Task.isCancelled {
            addonLock.lock()
            let until = wakingUntil
            addonLock.unlock()
            guard let until, until > Date() else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Does AIOStreams answer on its port?
    private nonisolated static func answers(timeout: TimeInterval = 3) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(aioPort)/api/v1/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return status < 500
    }

    // MARK: - Log file

    private nonisolated static var logFile: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("AIOStreams-logs", isDirectory: true).appendingPathComponent("run.log")
    }

    /// stdout and stderr (Node.js, AIOStreams and Nuvio's own prints) go
    /// straight to the log file: what was written survives a crash.
    private func openLog() {
        let file = Self.logFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        aioLogDescriptor = descriptor
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(descriptor, STDOUT_FILENO)
        dup2(descriptor, STDERR_FILENO)
        Self.installCrashNotes()
    }

    /// A line of Nuvio's own in the log file.
    nonisolated static func note(_ text: String) {
        let descriptor = aioLogDescriptor
        guard descriptor >= 0 else { return }
        let line = "[nuvio] \(text)\n"
        line.withCString { _ = write(descriptor, $0, strlen($0)) }
    }

    /// The log is read only while it is on screen (the AIOStreams sheet).
    func setLogVisible(_ visible: Bool) {
        logVisible = visible
        if visible {
            refreshLog()
            startLogTimer()
        } else {
            logTimer?.invalidate()
            logTimer = nil
        }
    }

    private func startLogTimer() {
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AIOStreamsHost.shared.refreshLog() }
        }
    }

    func refreshLog() {
        guard let text = Self.tail(of: Self.logFile, bytes: 48 * 1024) else { return }
        logLines = Array(text.split(separator: "\n").suffix(400).map { Self.shorten(String($0)) })
        // With a detailed log AIOStreams logs every request: keep the file small.
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.logFile.path))?[.size] as? UInt64 ?? 0
        if size > 16 << 20, aioLogDescriptor >= 0 {
            ftruncate(aioLogDescriptor, 0)
            Self.note("log trimmed")
        }
    }

    private func loadPreviousRun() {
        guard let text = Self.tail(of: Self.logFile, bytes: 32 * 1024), !text.isEmpty else { return }
        let record = UserDefaults.standard.dictionary(forKey: Self.runRecordKey)
        let kind = RunKind(rawValue: record?["kind"] as? String ?? "") ?? .aio
        let ready = record?["ready"] as? Bool ?? true
        let lines = text.split(separator: "\n").map(String.init)
        var summary = "Ended when Nuvio was closed"
        var unexpected = true
        if let crash = lines.last(where: { $0.hasPrefix("[nuvio] CRASH:") }) {
            summary = "Crashed — " + String(crash.dropFirst("[nuvio] CRASH: ".count))
        } else if lines.contains(where: { $0.hasPrefix("[nuvio] exit() was called") }) {
            summary = "Node.js closed the app (exit)"
        } else if let exited = lines.last(where: { $0.hasPrefix("[nuvio] Node.js exited") }) {
            summary = String(exited.dropFirst("[nuvio] ".count))
            unexpected = !exited.hasSuffix("code 0")
        } else if kind == .aio && !ready {
            summary = "Ended during the start without a message — tvOS probably closed Nuvio (memory?)"
        } else {
            unexpected = false
        }
        lastStartUnfinished = kind == .aio && !ready
        let date = record?["date"] as? Date
        previousRun = PreviousRun(
            summary: (kind == .nodeTest ? "Node.js test: " : "") + summary,
            unexpected: unexpected,
            date: date,
            lines: Array(lines.suffix(80).map(Self.shorten))
        )
    }

    private nonisolated static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    /// AIOStreams logs JSON (pino); the message is what matters on a TV.
    private nonisolated static func shorten(_ line: String) -> String {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return String(line.prefix(400))
        }
        let level = (object["level"] as? Int).map { $0 >= 50 ? "✕ " : $0 >= 40 ? "! " : "" } ?? ""
        let module = (object["module"] as? String).map { "[\($0)] " } ?? ""
        let message = object["msg"] as? String ?? line
        return String((level + module + message).prefix(400))
    }

    // MARK: - Crash notes

    private nonisolated static func installCrashNotes() {
        guard !aioCrashNotesInstalled else { return }
        aioCrashNotesInstalled = true
        // Touch the buffers now: never for the first time inside a signal handler.
        _ = aioFrames
        _ = aioPreviousActions
        for number in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS] {
            let name = String(cString: strsignal(number))
            aioSignalNotes[Int(number)] = strdup("\n[nuvio] CRASH: signal \(number) (\(name))\n[nuvio] native stack:\n")
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = aioNoteSignal
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(number, &action, aioPreviousActions + Int(number))
        }
        atexit(aioNoteExit)
    }

    private nonisolated static func deviceDescription() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(machine) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    nonisolated static func memoryDescription() -> String {
        let available = os_proc_available_memory() / 1_048_576
        return "Nuvio \(appFootprintMB() ?? -1) MB, tvOS allows \(available) MB more"
    }

    // MARK: - Node

    private typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

    private nonisolated static func nodeStartFunction() -> NodeStart? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "node_start") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: NodeStart.self)
    }

    /// node_start with argv in one contiguous block, as Node expects.
    private nonisolated static func run(_ nodeStart: NodeStart, arguments: [String]) -> Int32 {
        let bytes = arguments.reduce(0) { $0 + $1.utf8.count + 1 }
        let block = UnsafeMutablePointer<CChar>.allocate(capacity: bytes)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        var cursor = block
        for (index, argument) in arguments.enumerated() {
            argv[index] = cursor
            argument.withCString { source in
                let length = strlen(source)
                cursor.update(from: source, count: length + 1)
                cursor += length + 1
            }
        }
        argv[arguments.count] = nil
        // Node keeps pointers into argv for the life of the process.
        return nodeStart(Int32(arguments.count), argv)
    }

    /// What "Test Node.js only" runs: each step prints its result or its error.
    /// The downloads compare AIOStreams' way (fetch: undici, whose HTTP parser
    /// is WebAssembly, emulated in JavaScript on Apple TV) with Node.js' own
    /// native parser (node:https).
    private nonisolated static let nodeTestScript = #"""
    const out = (text) => console.log('[node-test] ' + text);
    const step = async (name, run) => {
      const begin = Date.now();
      try { out(`${name}: ${await run()} (${Date.now() - begin} ms)`); }
      catch (error) { out(`${name} FAILED: ${(error && error.stack) || error}`); }
    };
    out(`Node ${process.version} · V8 ${process.versions.v8} · ${process.platform}/${process.arch} · flags ${process.config.variables.node_v8_options || '-'}`);
    await step('memory', () => Object.entries(process.memoryUsage()).map(([key, value]) => `${key} ${Math.round(value / 1048576)} MB`).join(', '));
    await step('WebAssembly', () => typeof WebAssembly);
    await step('crypto', async () => (await import('node:crypto')).createHash('sha256').update('nuvio').digest('hex').slice(0, 16));
    await step('zlib', async () => { const zlib = await import('node:zlib'); return zlib.gunzipSync(zlib.gzipSync('nuvio')).toString(); });
    await step('files', async () => { const fs = await import('node:fs'); const file = (process.env.TMPDIR || '/tmp') + '/nuvio-node-test.txt'; fs.writeFileSync(file, 'ok'); return fs.readFileSync(file, 'utf8'); });
    await step('sqlite', async () => { const { DatabaseSync } = await import('node:sqlite'); const db = new DatabaseSync(':memory:'); return db.prepare('select sqlite_version() as version').get().version; });
    await step('http server', async () => {
      const http = await import('node:http');
      const server = http.createServer((request, response) => response.end('pong'));
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      const text = await (await fetch(`http://127.0.0.1:${server.address().port}/`)).text();
      server.close();
      return text;
    });
    await step('fetch https', async () => { const response = await fetch('https://www.apple.com/library/test/success.html'); return `${response.status}, ${(await response.text()).length} B`; });
    await step('cpu', () => { let sum = 0; for (let i = 0; i < 20000000; i++) sum += i % 7; return `20M loop, sum ${sum}`; });
    const https = await import('node:https');
    const agent = new https.Agent({ keepAlive: true });
    const big = 'https://cdn.jsdelivr.net/npm/typescript@5.6.3/lib/typescript.js';
    const small = 'https://cdn.jsdelivr.net/npm/ms@2.1.3/package.json';
    const viaFetch = async (url) => (await (await fetch(url, { headers: { 'accept-encoding': 'identity' } })).arrayBuffer()).byteLength;
    const viaHttps = (url) => new Promise((resolve, reject) => {
      https.get(url, { agent, headers: { 'accept-encoding': 'identity' } }, (response) => {
        let bytes = 0;
        response.on('data', (chunk) => { bytes += chunk.length; });
        response.on('end', () => resolve(bytes));
        response.on('error', reject);
      }).on('error', reject);
    });
    const mb = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`;
    for (const round of [1, 2]) {
      await step(`big download, fetch (AIOStreams' way) #${round}`, async () => mb(await viaFetch(big)));
      await step(`big download, node:https (native) #${round}`, async () => mb(await viaHttps(big)));
    }
    await step('20 small requests, fetch', async () => { for (let i = 0; i < 20; i++) await viaFetch(small); return 'done'; });
    await step('20 small requests, node:https', async () => { for (let i = 0; i < 20; i++) await viaHttps(small); return 'done'; });
    await step('memory after', () => `${Math.round(process.memoryUsage().rss / 1048576)} MB`);
    agent.destroy();
    out('done');
    """#

    private nonisolated static func secret() -> String {
        if let saved = UserDefaults.standard.string(forKey: secretKey), saved.count == 64 { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(secret, forKey: secretKey)
        return secret
    }

    private nonisolated static func appFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}

// MARK: - Crash notes (plain C-style state: used from signal handlers)

/// The log file, once opened (stdout and stderr point to it as well).
private nonisolated(unsafe) var aioLogDescriptor: Int32 = -1
private nonisolated(unsafe) var aioCrashNotesInstalled = false

private nonisolated(unsafe) let aioFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
    let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    frames.initialize(repeating: nil, count: 128)
    return frames
}()

private nonisolated(unsafe) let aioPreviousActions: UnsafeMutablePointer<sigaction> = {
    let actions = UnsafeMutablePointer<sigaction>.allocate(capacity: 32)
    actions.initialize(repeating: sigaction(), count: 32)
    return actions
}()

private nonisolated(unsafe) let aioSignalNotes: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
    let notes = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32)
    notes.initialize(repeating: nil, count: 32)
    return notes
}()

/// A fatal signal: the note and the native stack into the log file, then the
/// previous handling takes over (the faulting instruction or abort() raises
/// the signal again, and the app crashes as it would have).
private func aioNoteSignal(_ number: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?) {
    guard number > 0, number < 32 else { return }
    let descriptor = aioLogDescriptor
    if descriptor >= 0, let note = aioSignalNotes[Int(number)] {
        _ = write(descriptor, note, strlen(note))
        let count = backtrace(aioFrames, 128)
        backtrace_symbols_fd(aioFrames, count, descriptor)
    }
    sigaction(number, aioPreviousActions + Int(number), nil)
}

/// exit() closes the whole app; Node.js calls it on a fatal error.
private func aioNoteExit() {
    let descriptor = aioLogDescriptor
    guard descriptor >= 0 else { return }
    let text: StaticString = "\n[nuvio] exit() was called: the app is closing\n[nuvio] native stack:\n"
    _ = write(descriptor, text.utf8Start, text.utf8CodeUnitCount)
    let count = backtrace(aioFrames, 128)
    backtrace_symbols_fd(aioFrames, count, descriptor)
}
