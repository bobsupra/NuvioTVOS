import Foundation
import CryptoKit
import Security

/// The active profile's plugin repositories and scrapers.
///
/// Repositories are added by the URL of their `manifest.json` (as on Android),
/// their scrapers' JavaScript is downloaded next to the manifest and kept in
/// files (`LargePayloadStore`, never `UserDefaults`), and the list of
/// repository URLs syncs with the account's `plugins` table so it matches the
/// Android and iOS apps. Scraper settings stay on this Apple TV, in Keychain.
@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    /// Posted when the user adds, removes or reorders repositories, with the
    /// editing profile's id under `profileIdUserInfoKey`; account sync pushes it.
    nonisolated static let repositoriesChangedNotification = Notification.Name("nuvio.tv.plugins.repositoriesChanged")
    nonisolated static let profileIdUserInfoKey = "profileId"

    struct State: Codable, Equatable {
        var pluginsEnabled = true
        var repositories: [PluginRepositoryRecord] = []
        var scrapers: [PluginScraperRecord] = []
    }

    @Published private(set) var state = State() {
        didSet {
            // Catalogs, metadata and ratings reach the app as virtual add-ons.
            if let loadedScope { PluginAddonRegistry.shared.update(state: state, scope: loadedScope) }
        }
    }
    /// Manifest URLs being downloaded right now.
    @Published private(set) var refreshing: Set<String> = []
    /// "Update Automatically": repositories are downloaded again at most once
    /// a day, when Nuvio starts or comes back to the foreground.
    @Published private(set) var autoUpdates: Bool

    nonisolated static let autoUpdateKey = "plugins.autoUpdate"
    nonisolated static let autoUpdateInterval: TimeInterval = 24 * 3600

    private var loadedScope: String?
    nonisolated private static let directory = "NuvioPlugins"

    private init() {
        autoUpdates = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true
    }

    // MARK: - Reading

    /// Reloads when the active profile changed since the last read.
    func ensureLoaded() {
        let scope = ProfileSettings.activeProfileScope
        guard scope != loadedScope else { return }
        loadedScope = scope
        state = Self.loadState(scope: scope)
    }

    var pluginsEnabled: Bool {
        ensureLoaded()
        return state.pluginsEnabled
    }

    var repositories: [PluginRepositoryRecord] {
        ensureLoaded()
        return state.repositories
    }

    func scrapers(in repositoryURL: String) -> [PluginScraperRecord] {
        ensureLoaded()
        return state.scrapers.filter { $0.repositoryURL == repositoryURL }
    }

    func scraper(id: String) -> PluginScraperRecord? {
        ensureLoaded()
        return state.scrapers.first { $0.id == id }
    }

    /// Scrapers to ask for this content type, in repository order.
    func activeScrapers(for type: String, resource: String = PluginResources.stream) -> [PluginScraperRecord] {
        ensureLoaded()
        guard state.pluginsEnabled else { return [] }
        let order = Dictionary(state.repositories.enumerated().map { ($1.manifestURL, $0) }, uniquingKeysWith: { first, _ in first })
        return state.scrapers
            .filter { $0.enabled && $0.manifestEnabled && $0.supports(type: type) && $0.provides(resource) }
            .sorted { (order[$0.repositoryURL] ?? .max) < (order[$1.repositoryURL] ?? .max) }
    }

    /// The scraper's JavaScript; downloads it again when the system purged the
    /// cached copy, or every time for a repository in developer mode. Code
    /// uploaded from the setup page (Developer Mode) wins over both.
    func code(for scraper: PluginScraperRecord) async -> String? {
        let scope = ProfileSettings.activeProfileScope
        if scraper.uploadedCode == true || state.scrapers.first(where: { $0.id == scraper.id })?.uploadedCode == true,
           let uploaded = Self.readCodeFile(key: Self.uploadKey(scope: scope, scraperID: scraper.id)) {
            return uploaded
        }
        let reload = state.repositories.first { $0.manifestURL == scraper.repositoryURL }?.alwaysReload == true
        if reload, let url = Self.codeURL(repositoryURL: scraper.repositoryURL, filename: scraper.filename),
           let fresh = try? await Self.downloadText(url) {
            Self.writeCode(fresh, scope: scope, scraperID: scraper.id)
            return fresh
        }
        if let code = Self.readCode(scope: scope, scraperID: scraper.id) { return code }
        guard let url = Self.codeURL(repositoryURL: scraper.repositoryURL, filename: scraper.filename),
              let code = try? await Self.downloadText(url) else { return nil }
        Self.writeCode(code, scope: scope, scraperID: scraper.id)
        return code
    }

    // MARK: - Editing

    func setPluginsEnabled(_ enabled: Bool) {
        ensureLoaded()
        state.pluginsEnabled = enabled
        persist()
        if enabled {
            if state.scrapers.contains(where: { $0.enabled }) { PluginLoopbackServer.shared.ensureRunning() }
        } else {
            // Nothing of the plugins runs: no contexts kept, no server.
            PluginInstancePool.shared.retireAll(idleOnly: false)
            PluginLoopbackServer.shared.stop()
        }
        PluginAIOBridge.changed()
    }

    /// "Through AIOStreams" (``PluginAIOBridge``).
    func setScraperThroughAIO(_ id: String, enabled: Bool) {
        ensureLoaded()
        guard let index = state.scrapers.firstIndex(where: { $0.id == id }) else { return }
        state.scrapers[index].throughAIO = enabled ? true : nil
        persist()
        if enabled, state.pluginsEnabled { PluginLoopbackServer.shared.ensureRunning() }
        PluginAIOBridge.changed()
    }

    func setScraperEnabled(_ id: String, enabled: Bool) {
        ensureLoaded()
        guard let index = state.scrapers.firstIndex(where: { $0.id == id }) else { return }
        state.scrapers[index].enabled = enabled
        persist()
        if !enabled { PluginInstancePool.shared.retire(scraperId: id) }
    }

    /// Adds a repository by its manifest URL (a GitHub page link to the file
    /// works too) and downloads its scrapers. Throws a message for the user.
    @discardableResult
    func addRepository(_ input: String) async throws -> PluginRepositoryRecord {
        ensureLoaded()
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isShortCode(input) {
            guard let resolved = await Self.resolveShortCode(input) else {
                throw PluginStoreError.download("The short code \(input) could not be resolved.")
            }
            input = resolved
        }
        guard let url = Self.normalizedManifestURL(input) else { throw PluginStoreError.invalidURL }
        let manifestURL = url.absoluteString
        if let existing = state.repositories.first(where: { $0.manifestURL == manifestURL }) {
            await refreshRepository(existing.manifestURL)
            return state.repositories.first { $0.manifestURL == manifestURL } ?? existing
        }
        let profileID = ProfileSettings.activeProfileID
        let (repository, scrapers) = try await Self.download(manifestURL: manifestURL, previous: [])
        guard ProfileSettings.activeProfileID == profileID else { throw CancellationError() }
        ensureLoaded()
        state.repositories.removeAll { $0.manifestURL == manifestURL }
        state.repositories.append(repository)
        state.scrapers.removeAll { $0.repositoryURL == manifestURL }
        state.scrapers.append(contentsOf: scrapers)
        persist()
        notifyRepositoriesChanged()
        return repository
    }

    /// Downloads the manifest and scrapers again; keeps the old copy and shows
    /// the error on the repository when that fails.
    func refreshRepository(_ manifestURL: String) async {
        ensureLoaded()
        guard state.repositories.contains(where: { $0.manifestURL == manifestURL }),
              !refreshing.contains(manifestURL) else { return }
        let profileID = ProfileSettings.activeProfileID
        refreshing.insert(manifestURL)
        defer { refreshing.remove(manifestURL) }
        let previous = state.scrapers.filter { $0.repositoryURL == manifestURL }
        do {
            let (repository, scrapers) = try await Self.download(manifestURL: manifestURL, previous: previous)
            guard ProfileSettings.activeProfileID == profileID else { return }
            ensureLoaded()
            guard let index = state.repositories.firstIndex(where: { $0.manifestURL == manifestURL }) else { return }
            var updated = repository
            updated.alwaysReload = state.repositories[index].alwaysReload
            state.repositories[index] = updated
            state.scrapers.removeAll { $0.repositoryURL == manifestURL }
            state.scrapers.append(contentsOf: scrapers)
            let kept = Set(scrapers.map(\.id))
            for old in previous where !kept.contains(old.id) {
                Self.removeCode(scope: ProfileSettings.activeProfileScope, scraperID: old.id)
            }
        } catch {
            guard ProfileSettings.activeProfileID == profileID,
                  let index = state.repositories.firstIndex(where: { $0.manifestURL == manifestURL }) else { return }
            state.repositories[index].errorMessage = error.localizedDescription
        }
        persist()
    }

    func refreshAll() async {
        for repository in repositories {
            await refreshRepository(repository.manifestURL)
        }
    }

    func removeRepository(_ manifestURL: String) {
        ensureLoaded()
        let scope = ProfileSettings.activeProfileScope
        for scraper in state.scrapers where scraper.repositoryURL == manifestURL {
            Self.removeCode(scope: scope, scraperID: scraper.id)
            PluginSettingsVault.remove(scraperID: scraper.id)
            PluginStorageFile.remove(scraperID: scraper.id, scope: scope)
            PluginFileStore.removeAll(scraperID: scraper.id, scope: scope)
            LargePayloadStore.remove(key: Self.uploadKey(scope: scope, scraperID: scraper.id), directory: Self.directory)
            PluginInstancePool.shared.retire(scraperId: scraper.id)
            PluginLogStore.shared.clear(scraper.id)
        }
        state.repositories.removeAll { $0.manifestURL == manifestURL }
        state.scrapers.removeAll { $0.repositoryURL == manifestURL }
        persist()
        notifyRepositoriesChanged()
    }

    func setAlwaysReload(_ manifestURL: String, enabled: Bool) {
        ensureLoaded()
        guard let index = state.repositories.firstIndex(where: { $0.manifestURL == manifestURL }) else { return }
        state.repositories[index].alwaysReload = enabled ? true : nil
        if !enabled {
            // Uploaded code belongs to Developer Mode.
            for scraper in state.scrapers where scraper.repositoryURL == manifestURL && scraper.uploadedCode == true {
                revertUploadedCode(scraper.id)
            }
        }
        persist()
    }

    /// Developer Mode: runs `code` instead of the repository's file, until
    /// reverted, Developer Mode is turned off or the repository is removed.
    func uploadCode(_ code: String, scraperID: String) throws {
        ensureLoaded()
        guard let index = state.scrapers.firstIndex(where: { $0.id == scraperID }) else {
            throw PluginStoreError.download("The provider was not found.")
        }
        let repositoryURL = state.scrapers[index].repositoryURL
        guard state.repositories.first(where: { $0.manifestURL == repositoryURL })?.alwaysReload == true else {
            throw PluginStoreError.download("Turn on Developer Mode for the repository first.")
        }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginStoreError.download("The file is empty.")
        }
        let scope = ProfileSettings.activeProfileScope
        guard LargePayloadStore.write(Data(code.utf8), key: Self.uploadKey(scope: scope, scraperID: scraperID), directory: Self.directory) else {
            throw PluginStoreError.download("The code could not be saved on this Apple TV.")
        }
        state.scrapers[index].uploadedCode = true
        persist()
        PluginInstancePool.shared.retire(scraperId: scraperID)
        PluginLogStore.shared.append(scraperID, level: .info, message: "Code uploaded from the setup page (\(code.utf8.count / 1_024) KB).")
    }

    /// Back to the repository's code.
    func revertUploadedCode(_ scraperID: String) {
        ensureLoaded()
        LargePayloadStore.remove(key: Self.uploadKey(scope: ProfileSettings.activeProfileScope, scraperID: scraperID), directory: Self.directory)
        guard let index = state.scrapers.firstIndex(where: { $0.id == scraperID }),
              state.scrapers[index].uploadedCode != nil else { return }
        state.scrapers[index].uploadedCode = nil
        persist()
        PluginInstancePool.shared.retire(scraperId: scraperID)
    }

    // MARK: - Automatic updates

    func setAutoUpdates(_ enabled: Bool) {
        autoUpdates = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoUpdateKey)
    }

    /// Nuvio started or came back to the foreground: updates the repositories
    /// when that is on and the last update is a day old, and starts the
    /// on-device server that plugin streams resolved on play go through.
    func appBecameActive() async {
        ensureLoaded()
        if state.pluginsEnabled, state.scrapers.contains(where: { $0.enabled }) {
            PluginLoopbackServer.shared.ensureRunning()
        }
        await updateRepositoriesIfDue()
    }

    func updateRepositoriesIfDue(now: Date = Date()) async {
        ensureLoaded()
        guard autoUpdates, state.pluginsEnabled, !state.repositories.isEmpty else { return }
        let key = "\(Self.autoUpdateKey).last.\(ProfileSettings.activeProfileScope)"
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           now.timeIntervalSince(last) < Self.autoUpdateInterval, last <= now {
            return
        }
        UserDefaults.standard.set(now, forKey: key)
        for repository in state.repositories {
            await refreshRepository(repository.manifestURL)
        }
    }

    func moveRepository(_ manifestURL: String, up: Bool) {
        ensureLoaded()
        guard let index = state.repositories.firstIndex(where: { $0.manifestURL == manifestURL }) else { return }
        let target = up ? index - 1 : index + 1
        guard state.repositories.indices.contains(target) else { return }
        state.repositories.swapAt(index, target)
        persist()
        notifyRepositoriesChanged()
    }

    // MARK: - Account sync

    /// The repository URLs in order, for `sync_push_plugins`.
    var repositoryURLsForSync: [(url: String, name: String)] {
        repositories.map { ($0.manifestURL, $0.name) }
    }

    /// Makes the local list match the account's: installs repositories that
    /// are new, drops ones the account no longer has, keeps the account's
    /// order. Returns false (and changes nothing) when the account has no
    /// plugins while this Apple TV does, so the caller can push instead —
    /// Android's first-sync rule.
    @discardableResult
    func applyRemoteRepositories(_ urls: [String], profileID: String) async -> Bool {
        guard ProfileSettings.activeProfileID == profileID else { return true }
        ensureLoaded()
        var seen = Set<String>()
        let remote = urls.compactMap { Self.normalizedManifestURL($0)?.absoluteString }.filter { seen.insert($0).inserted }
        if remote.isEmpty, !state.repositories.isEmpty { return false }
        if remote == state.repositories.map(\.manifestURL) { return true }

        let scope = ProfileSettings.activeProfileScope
        let remoteSet = Set(remote)
        for scraper in state.scrapers where !remoteSet.contains(scraper.repositoryURL) {
            Self.removeCode(scope: scope, scraperID: scraper.id)
        }
        state.scrapers.removeAll { !remoteSet.contains($0.repositoryURL) }
        let existing = Dictionary(state.repositories.map { ($0.manifestURL, $0) }, uniquingKeysWith: { first, _ in first })
        state.repositories = remote.map { url in
            existing[url] ?? PluginRepositoryRecord(
                manifestURL: url,
                name: Self.fallbackName(for: url),
                scraperCount: 0
            )
        }
        persist()

        for url in remote where existing[url] == nil {
            guard ProfileSettings.activeProfileID == profileID else { break }
            await refreshRepository(url)
        }
        return true
    }

    // MARK: - Internals

    private func persist() {
        guard let scope = loadedScope,
              let data = try? JSONEncoder().encode(state) else { return }
        LargePayloadStore.write(data, key: "\(scope).state", directory: Self.directory)
    }

    private func notifyRepositoriesChanged() {
        NotificationCenter.default.post(
            name: Self.repositoriesChangedNotification,
            object: nil,
            userInfo: [Self.profileIdUserInfoKey: ProfileSettings.activeProfileID ?? ""]
        )
    }

    nonisolated static func loadState(scope: String) -> State {
        guard let data = LargePayloadStore.read(key: "\(scope).state", directory: directory),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    private static func download(
        manifestURL: String,
        previous: [PluginScraperRecord]
    ) async throws -> (PluginRepositoryRecord, [PluginScraperRecord]) {
        guard let url = URL(string: manifestURL) else { throw PluginStoreError.invalidURL }
        let data: Data
        do {
            data = try await downloadData(url)
        } catch {
            throw PluginStoreError.download("The manifest could not be downloaded: \(error.localizedDescription)")
        }
        let manifest = try PluginManifest.parse(data, fallbackName: fallbackName(for: manifestURL))
        let rawScrapers = PluginManifest.rawScrapers(data)
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scope = ProfileSettings.activeProfileScope

        var scrapers: [PluginScraperRecord] = []
        var failures: [String] = []
        for info in manifest.scrapers where info.isSupportedOnAppleTV {
            guard let codeURL = codeURL(repositoryURL: manifestURL, filename: info.filename) else {
                failures.append(info.name)
                continue
            }
            do {
                let code = try await downloadText(codeURL)
                let id = PluginScraperRecord.makeID(repositoryURL: manifestURL, scraperID: info.id)
                writeCode(code, scope: scope, scraperID: id)
                let old = previousByID[id]
                scrapers.append(PluginScraperRecord(
                    id: id,
                    repositoryURL: manifestURL,
                    scraperID: info.id,
                    name: info.name,
                    description: info.description ?? "",
                    version: info.version,
                    filename: info.filename,
                    supportedTypes: info.supportedTypes,
                    enabled: info.enabled ? (old?.enabled ?? true) : false,
                    manifestEnabled: info.enabled,
                    hasSettings: info.hasSettings,
                    logo: info.logo,
                    contentLanguage: info.contentLanguage,
                    formats: info.formats,
                    declaresSeriesType: info.declaresSeries,
                    resources: info.resources,
                    idPrefixes: info.idPrefixes.isEmpty ? nil : info.idPrefixes,
                    catalogsJSON: PluginManifest.jsonArrayText(rawScrapers[info.id]?["catalogs"]),
                    ratingSourcesJSON: PluginManifest.jsonArrayText(rawScrapers[info.id]?["ratingSources"]),
                    keepAlive: info.runsPersistently ? true : nil,
                    configPage: info.configPage ? true : nil,
                    uploadedCode: old?.uploadedCode,
                    throughAIO: old?.throughAIO
                ))
            } catch {
                failures.append(info.name)
            }
        }
        guard !scrapers.isEmpty else {
            if manifest.scrapers.contains(where: \.isSupportedOnAppleTV) {
                throw PluginStoreError.download("The providers' code could not be downloaded.")
            }
            throw PluginStoreError.noSupportedScrapers
        }
        let repository = PluginRepositoryRecord(
            manifestURL: manifestURL,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            author: manifest.author,
            scraperCount: scrapers.count,
            lastUpdated: Date(),
            errorMessage: failures.isEmpty ? nil : "Not downloaded: \(failures.joined(separator: ", "))"
        )
        return (repository, scrapers)
    }

    /// A repository short code as Android TV accepts them (`cspr`, `megarepo`):
    /// letters, digits, `-` and `_` only, resolved through cutt.ly.
    nonisolated static func isShortCode(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("://"), !text.contains("/"), !text.contains(".") else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Follows `https://cutt.ly/<code>` to where it points, as Android TV does.
    private static func resolveShortCode(_ code: String) async -> String? {
        guard let url = URL(string: "https://cutt.ly/\(code)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request, delegate: PluginNoRedirectDelegate.shared),
              let http = response as? HTTPURLResponse else { return nil }
        if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), !location.isEmpty {
            return location
        }
        // Some shorteners answer 200 after their own redirects; use where it ended.
        guard (200..<300).contains(http.statusCode), let final = http.url, final.host != "cutt.ly" else { return nil }
        return final.absoluteString
    }

    /// Accepts a raw manifest URL, a GitHub `blob` page link or a repository
    /// root (where `manifest.json` is appended), always over http(s); another
    /// scheme (`stremio://`, `nuvio://`) becomes https, as on Android TV.
    nonisolated static func normalizedManifestURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            if scheme != "http", scheme != "https" { text = "https://" + text[schemeEnd.upperBound...] }
        } else {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.fragment = nil
        if host == "github.com" {
            // github.com/<owner>/<repo>/blob/<branch>/<path> → raw file.
            let parts = components.path.split(separator: "/").map(String.init)
            if parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
                components.host = "raw.githubusercontent.com"
                components.path = "/" + ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
                components.query = nil
            }
        }
        if !components.path.lowercased().hasSuffix(".json") {
            components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "manifest.json"
        }
        return components.url
    }

    /// The scraper file next to the manifest, as Android resolves it.
    nonisolated static func codeURL(repositoryURL: String, filename: String) -> URL? {
        if filename.lowercased().hasPrefix("http://") || filename.lowercased().hasPrefix("https://") {
            return URL(string: filename)
        }
        let base = repositoryURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? repositoryURL
        let directory = base.hasSuffix("/manifest.json")
            ? String(base.dropLast("/manifest.json".count))
            : String(base[..<(base.lastIndex(of: "/") ?? base.endIndex)])
        let path = filename.drop { $0 == "/" }
        return URL(string: "\(directory)/\(path)")
    }

    nonisolated static func fallbackName(for manifestURL: String) -> String {
        guard let url = URL(string: manifestURL) else { return manifestURL }
        if url.host == "raw.githubusercontent.com" {
            let parts = url.path.split(separator: "/")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return url.host ?? manifestURL
    }

    private static func downloadData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(PluginRuntime.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PluginStoreError.download("HTTP \(http.statusCode)")
        }
        return data
    }

    private static func downloadText(_ url: URL) async throws -> String {
        let data = try await downloadData(url)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PluginStoreError.download("Empty file")
        }
        return text
    }

    private static func uploadKey(scope: String, scraperID: String) -> String {
        let digest = SHA256.hash(data: Data(scraperID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(scope).upload.\(digest)"
    }

    private static func codeKey(scope: String, scraperID: String) -> String {
        let digest = SHA256.hash(data: Data(scraperID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(scope).code.\(digest)"
    }

    private static func readCodeFile(key: String) -> String? {
        LargePayloadStore.read(key: key, directory: directory).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func readCode(scope: String, scraperID: String) -> String? {
        readCodeFile(key: codeKey(scope: scope, scraperID: scraperID))
    }

    private static func writeCode(_ code: String, scope: String, scraperID: String) {
        LargePayloadStore.write(Data(code.utf8), key: codeKey(scope: scope, scraperID: scraperID), directory: directory)
    }

    private static func removeCode(scope: String, scraperID: String) {
        LargePayloadStore.remove(key: codeKey(scope: scope, scraperID: scraperID), directory: directory)
    }
}

/// Each scraper's settings (the values of its `onSettings()` form) as a JSON
/// object in Keychain, per profile: they often hold API keys.
enum PluginSettingsVault {
    private static let service = "com.nuvio.tv.plugins.settings"

    static func settings(scraperID: String, profileScope: String = ProfileSettings.activeProfileScope) -> [String: Any] {
        var query = baseQuery(scraperID, profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    @discardableResult
    static func save(_ settings: [String: Any], scraperID: String, profileScope: String = ProfileSettings.activeProfileScope) -> Bool {
        guard JSONSerialization.isValidJSONObject(settings),
              let data = try? JSONSerialization.data(withJSONObject: settings) else { return false }
        // Cached plugin answers may depend on the old values.
        Task {
            await PluginSubtitleCache.shared.removeAll()
            await PluginAddonResponseCache.shared.removeAll()
        }
        var add = baseQuery(scraperID, profileScope)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(
                baseQuery(scraperID, profileScope) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func remove(scraperID: String, profileScope: String = ProfileSettings.activeProfileScope) -> Bool {
        let status = SecItemDelete(baseQuery(scraperID, profileScope) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(_ scraperID: String, _ profileScope: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(scraperID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(profileScope)"
        ]
    }
}
