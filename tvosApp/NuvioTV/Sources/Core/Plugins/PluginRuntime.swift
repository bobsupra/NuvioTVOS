import Foundation
import JavaScriptCore
import CryptoKit
import Security

/// Why a plugin call did not return a value.
enum PluginRuntimeError: LocalizedError, Equatable {
    /// The plugin exports no function with this name (module.exports or a global).
    case missingFunction(String)
    case timedOut(TimeInterval)
    /// The script threw, or rejected, with this message.
    case script(String)

    var errorDescription: String? {
        switch self {
        case .missingFunction(let name):
            return "The plugin has no \(name)() function."
        case .timedOut(let seconds):
            return "The plugin did not answer within \(Int(seconds)) s."
        case .script(let message):
            return message.split(separator: "\n").first.map(String.init) ?? message
        }
    }
}

/// Runs plugin JavaScript in JavaScriptCore. A context evaluates the
/// polyfills, sets `SCRAPER_ID` / `SCRAPER_SETTINGS`, loads the plugin inside
/// the same `module.exports` wrapper Android uses, and then calls exported
/// functions and waits for their (possibly async) results as JSON.
///
/// By default every call gets a fresh context, as on Android (each scraper
/// in its own QuickJS runtime). A provider written for Apple TV (its manifest
/// lists `tvos` in `supportedPlatforms`, or says `"keepAlive": true`) keeps
/// one context while Nuvio runs instead: it is loaded once, module-level
/// variables and timers survive between calls, and a big plugin doesn't pay
/// for loading its code on every search. See ``PluginInstancePool``.
enum PluginRuntime {
    /// Matches Android's per-call plugin timeout.
    static let defaultTimeout: TimeInterval = 60
    /// Stream searches get the same minute as on Android.
    static let streamTimeout: TimeInterval = 60
    static let maxResponseBytes = 20 * 1024 * 1024
    /// The default `User-Agent` of plugin requests — the desktop one the
    /// Android apps send, which sites that plugins scrape expect.
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    /// Network for plugin `fetch`. No cookies and no cache, like Android's
    /// plain OkHttp client, so one plugin never sees another plugin's cookies.
    /// Tests replace it with a session whose protocol classes stub responses.
    static var session: URLSession = makeSession(configuration: .ephemeral)

    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// Calls `function` in the plugin and returns its JSON result
    /// (`JSONSerialization` objects; `NSNull` for null / undefined).
    ///
    /// - Parameters:
    ///   - keepAlive: reuse the provider's long-lived context (see the type).
    ///   - emitArgument: index of an object argument that gets `emit(list)`;
    ///     every `emit` reaches `onEmit` with the list as JSON text
    ///     (progressive results).
    static func call(
        code: String,
        scraperId: String,
        settings: [String: Any] = [:],
        function: String,
        arguments: [Any] = [],
        timeout: TimeInterval = defaultTimeout,
        keepAlive: Bool = false,
        emitArgument: Int? = nil,
        onEmit: (@Sendable (String) -> Void)? = nil
    ) async throws -> Any {
        let scope = ProfileSettings.activeProfileScope
        let tmdbKey = TmdbDetailsService.currentApiKey ?? ""
        let currentSession = session
        let make = {
            PluginInstance(
                scraperId: scraperId,
                code: code,
                settings: settings,
                session: currentSession,
                storageScope: scope,
                tmdbApiKey: tmdbKey,
                fingerprint: fingerprint(code: code, settings: settings, scope: scope, tmdbKey: tmdbKey, session: currentSession)
            )
        }
        let instance = keepAlive
            ? PluginInstancePool.shared.instance(scraperId: scraperId, fingerprint: fingerprint(code: code, settings: settings, scope: scope, tmdbKey: tmdbKey, session: currentSession), make: make)
            : make()
        let started = Date()
        defer {
            if !keepAlive { instance.retire() }
        }
        do {
            let value = try await instance.invoke(
                function: function,
                arguments: arguments,
                timeout: timeout,
                emitArgument: emitArgument,
                onEmit: onEmit
            )
            logDuration(scraperId: scraperId, function: function, since: started, failed: false)
            return value
        } catch let error as PluginRuntimeError {
            if case .timedOut = error {
                // A context stuck in a loop would block every later call.
                PluginInstancePool.shared.retire(instance)
            }
            logDuration(scraperId: scraperId, function: function, since: started, failed: true)
            throw error
        }
    }

    private static func logDuration(scraperId: String, function: String, since started: Date, failed: Bool) {
        let seconds = Date().timeIntervalSince(started)
        let text = String(format: "⏱ %@ %@ in %.1f s", function, failed ? "failed" : "answered", seconds)
        PluginLogStore.shared.append(scraperId, level: .net, message: text)
    }

    static func fingerprint(code: String, settings: [String: Any], scope: String, tmdbKey: String, session: URLSession) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(code.utf8))
        let settingsData = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data()
        hasher.update(data: settingsData)
        hasher.update(data: Data("\u{0}\(scope)\u{0}\(tmdbKey)\u{0}\(ObjectIdentifier(session).hashValue)".utf8))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// JSON text for a value JavaScript can read as a literal (strings and
    /// other fragments included).
    static func jsonLiteral(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Kept-alive plugin contexts, one per provider: reused while the code,
/// settings, profile and TMDB key stay the same, dropped after 10 idle
/// minutes, beyond 12 providers (least recently used first) and on a memory
/// warning.
final class PluginInstancePool: @unchecked Sendable {
    static let shared = PluginInstancePool()
    static let idleLifetime: TimeInterval = 10 * 60
    static let maxInstances = 12

    private let lock = NSLock()
    private var instances: [String: PluginInstance] = [:]
    private var sweepTimer: DispatchSourceTimer?
    private var memoryObserver: NSObjectProtocol?

    func instance(scraperId: String, fingerprint: String, make: () -> PluginInstance) -> PluginInstance {
        lock.lock()
        defer { lock.unlock() }
        if let existing = instances[scraperId], existing.fingerprint == fingerprint, !existing.isRetired {
            return existing
        }
        instances[scraperId]?.retire()
        let created = make()
        instances[scraperId] = created
        if instances.count > Self.maxInstances {
            let idle = instances.values.filter { !$0.isBusy && $0 !== created }.sorted { $0.lastUsed < $1.lastUsed }
            for old in idle.prefix(instances.count - Self.maxInstances) {
                instances[old.scraperId] = nil
                old.retire()
            }
        }
        startHousekeepingIfNeeded()
        return created
    }

    func retire(_ instance: PluginInstance) {
        lock.lock()
        if instances[instance.scraperId] === instance { instances[instance.scraperId] = nil }
        lock.unlock()
        instance.retire()
    }

    /// A provider was removed or turned off.
    func retire(scraperId: String) {
        lock.lock()
        let instance = instances.removeValue(forKey: scraperId)
        lock.unlock()
        instance?.retire()
    }

    func retireAll(idleOnly: Bool) {
        lock.lock()
        let victims = instances.values.filter { !idleOnly || !$0.isBusy }
        for victim in victims { instances[victim.scraperId] = nil }
        lock.unlock()
        victims.forEach { $0.retire() }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return instances.count
    }

    private func sweep() {
        let limit = Date().addingTimeInterval(-Self.idleLifetime)
        lock.lock()
        let victims = instances.values.filter { !$0.isBusy && $0.lastUsed < limit }
        for victim in victims { instances[victim.scraperId] = nil }
        lock.unlock()
        victims.forEach { $0.retire() }
    }

    /// Lock held.
    private func startHousekeepingIfNeeded() {
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweepTimer = timer
        memoryObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.retireAll(idleOnly: true)
        }
    }
}

/// One plugin context with its timers, requests and storage. All JavaScript
/// runs on `queue`. Calls are told apart by an id, so a kept-alive context
/// can serve several at once; each ends once — by the script, its timeout or
/// a cancel. The timeout fires from another queue, so a script stuck in a
/// loop still returns control to the caller.
final class PluginInstance: @unchecked Sendable {
    let scraperId: String
    let fingerprint: String
    private let code: String
    private let settings: [String: Any]
    private let session: URLSession
    private let storageScope: String
    private let tmdbApiKey: String
    private let queue: DispatchQueue

    private final class Call {
        let id: Int
        let function: String
        let onEmit: (@Sendable (String) -> Void)?
        var continuation: CheckedContinuation<Any, Error>?
        var earlyResult: Result<Any, Error>?
        var timeout: DispatchWorkItem?

        init(id: Int, function: String, onEmit: (@Sendable (String) -> Void)?) {
            self.id = id
            self.function = function
            self.onEmit = onEmit
        }
    }

    private let lock = NSLock()
    private var calls: [Int: Call] = [:]
    private var nextCallID = 1
    private var retired = false
    private var tornDown = false
    private var lastUsedDate = Date()

    // Confined to `queue`.
    private enum LoadState {
        case notLoaded
        case loaded
        case failed(String)
    }
    private var loadState = LoadState.notLoaded
    private var context: JSContext?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var pendingException: String?
    private let dom = PluginDOMStore()
    private var storage: [String: String]?
    private var storageBytes = 0
    private var storageDirty = false
    private lazy var files = PluginFileStore(scraperID: scraperId, scope: storageScope)

    init(
        scraperId: String,
        code: String,
        settings: [String: Any],
        session: URLSession,
        storageScope: String,
        tmdbApiKey: String = "",
        fingerprint: String = ""
    ) {
        self.scraperId = scraperId
        self.code = code
        self.settings = settings
        self.session = session
        self.storageScope = storageScope
        self.tmdbApiKey = tmdbApiKey
        self.fingerprint = fingerprint
        self.queue = DispatchQueue(label: "nuvio.plugin.instance", qos: .userInitiated)
    }

    var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !calls.isEmpty
    }

    var lastUsed: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastUsedDate
    }

    /// No new calls; the context goes away once the running ones end.
    func retire() {
        lock.lock()
        retired = true
        let idle = calls.isEmpty
        lock.unlock()
        if idle { queue.async { self.teardown() } }
    }

    func invoke(
        function: String,
        arguments: [Any],
        timeout: TimeInterval,
        emitArgument: Int? = nil,
        onEmit: (@Sendable (String) -> Void)? = nil
    ) async throws -> Any {
        lock.lock()
        let id = nextCallID
        nextCallID += 1
        let call = Call(id: id, function: function, onEmit: onEmit)
        calls[id] = call
        lastUsedDate = Date()
        lock.unlock()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                lock.lock()
                if let early = call.earlyResult {
                    lock.unlock()
                    continuation.resume(with: early)
                    return
                }
                call.continuation = continuation
                let item = DispatchWorkItem { [weak self] in
                    self?.finish(id, .failure(PluginRuntimeError.timedOut(timeout)))
                }
                call.timeout = item
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
                queue.async {
                    self.start(id, function: function, arguments: arguments, emitArgument: emitArgument)
                }
            }
        } onCancel: {
            self.finish(id, .failure(CancellationError()))
        }
    }

    // MARK: - Lifecycle

    private func isPending(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls[id] != nil
    }

    private func start(_ id: Int, function: String, arguments: [Any], emitArgument: Int?) {
        guard isPending(id) else { return }
        if case .notLoaded = loadState { load() }
        if case .failed(let message) = loadState {
            finish(id, .failure(PluginRuntimeError.script(message)))
            return
        }
        guard let context else {
            finish(id, .failure(CancellationError()))
            return
        }
        let nameLiteral = PluginRuntime.jsonLiteral(function) ?? "\"\""
        let argumentsLiteral = PluginRuntime.jsonLiteral(arguments) ?? "[]"
        let emitLiteral = emitArgument.map(String.init) ?? "-1"
        // An error another call's callback left behind isn't this call's.
        pendingException = nil
        context.evaluateScript("__nuvioInvoke(\(nameLiteral), \(argumentsLiteral), \(id), \(emitLiteral));")
        if let message = takeException() {
            finish(id, .failure(PluginRuntimeError.script(message)))
        }
    }

    /// Creates the context and loads the plugin. On `queue`.
    private func load() {
        guard let context = JSContext() else {
            loadState = .failed("JavaScript could not start.")
            return
        }
        self.context = context
        context.name = "Nuvio plugin"
        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            let message = PluginInstance.describe(exception)
            self.pendingException = message
            PluginLogStore.shared.append(self.scraperId, level: .error, message: message)
        }
        installNatives(in: context)

        context.evaluateScript(PluginPolyfills.source, withSourceURL: URL(string: "nuvio://polyfills.js"))
        if let message = takeException() {
            loadState = .failed("The plugin environment failed to load: \(message)")
            return
        }

        let idLiteral = PluginRuntime.jsonLiteral(scraperId) ?? "\"\""
        let settingsLiteral = PluginRuntime.jsonLiteral(settings) ?? "{}"
        // TMDB_API_KEY as on Android: plugins look titles up on TMDB with it
        // (empty without a key in Settings → Integrations → TMDB).
        let tmdbLiteral = PluginRuntime.jsonLiteral(tmdbApiKey) ?? "\"\""
        context.evaluateScript(
            "globalThis.SCRAPER_ID = \(idLiteral);\nglobalThis.SCRAPER_SETTINGS = \(settingsLiteral);\n"
                + "globalThis.TMDB_API_KEY = \(tmdbLiteral);"
        )

        let wrapped = "var module = { exports: {} };\nvar exports = module.exports;\n(function() {\n\(code)\n})();"
        context.evaluateScript(wrapped, withSourceURL: URL(string: "plugin://scraper.js"))
        if let message = takeException() {
            loadState = .failed(message)
            return
        }
        loadState = .loaded
    }

    private func finish(_ id: Int, _ result: Result<Any, Error>) {
        lock.lock()
        guard let call = calls[id] else {
            lock.unlock()
            return
        }
        guard let continuation = call.continuation else {
            // Cancelled before the call started waiting.
            if call.earlyResult == nil { call.earlyResult = result }
            calls[id] = nil
            let idle = calls.isEmpty && retired
            lock.unlock()
            if idle { queue.async { self.teardown() } }
            return
        }
        calls[id] = nil
        call.continuation = nil
        call.timeout?.cancel()
        lastUsedDate = Date()
        let idle = calls.isEmpty && retired
        lock.unlock()

        continuation.resume(with: result)
        queue.async {
            self.saveStorageIfNeeded()
            if idle { self.teardown() }
        }
    }

    private func saveStorageIfNeeded() {
        if storageDirty, let storage {
            PluginStorageFile.save(storage, scraperID: scraperId, scope: storageScope)
            storageDirty = false
        }
    }

    private func teardown() {
        lock.lock()
        guard !tornDown, calls.isEmpty, retired else {
            lock.unlock()
            return
        }
        tornDown = true
        lock.unlock()
        saveStorageIfNeeded()
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        context?.exceptionHandler = nil
        context = nil
    }

    private func takeException() -> String? {
        defer { pendingException = nil }
        return pendingException
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "Unknown JavaScript error" }
        var message = exception.toString() ?? "Unknown JavaScript error"
        if let line = exception.objectForKeyedSubscript("line"), line.isNumber {
            message += " (line \(line.toInt32()))"
        }
        if let stack = exception.objectForKeyedSubscript("stack"), stack.isString,
           let text = stack.toString(), !text.isEmpty {
            message += "\n" + text
        }
        return message
    }

    // MARK: - Natives

    private func installNatives(in context: JSContext) {
        guard let native = JSValue(newObjectIn: context) else { return }

        let log: @convention(block) (JSValue, JSValue) -> Void = { [weak self] level, message in
            guard let self else { return }
            let logLevel = PluginLogLevel(rawValue: level.toString() ?? "") ?? .log
            PluginLogStore.shared.append(self.scraperId, level: logLevel, message: message.toString() ?? "")
        }
        let setTimer: @convention(block) (JSValue, JSValue) -> Void = { [weak self] id, milliseconds in
            self?.setTimer(Int(id.toInt32()), milliseconds: max(0, milliseconds.toDouble()))
        }
        let clearTimer: @convention(block) (JSValue) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: Int(id.toInt32()))?.cancel()
        }
        let fetch: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] id, url, options in
            self?.startFetch(id: Int(id.toInt32()), url: url.toString() ?? "", optionsJSON: options.toString() ?? "{}")
        }
        let abortFetch: @convention(block) (JSValue) -> Void = { [weak self] id in
            self?.tasks.removeValue(forKey: Int(id.toInt32()))?.cancel()
        }
        let digest: @convention(block) (JSValue, JSValue) -> String = { algorithm, base64 in
            let data = Data(base64Encoded: base64.toString() ?? "") ?? Data()
            return PluginInstance.digest(algorithm.toString() ?? "", data)?.base64EncodedString() ?? ""
        }
        let hmac: @convention(block) (JSValue, JSValue, JSValue) -> String = { algorithm, key, base64 in
            let keyData = Data(base64Encoded: key.toString() ?? "") ?? Data()
            let data = Data(base64Encoded: base64.toString() ?? "") ?? Data()
            return PluginInstance.hmac(algorithm.toString() ?? "", key: keyData, data: data)?.base64EncodedString() ?? ""
        }
        let randomBytes: @convention(block) (JSValue) -> String = { count in
            let length = min(max(Int(count.toInt32()), 0), 65_536)
            var bytes = [UInt8](repeating: 0, count: length)
            if length > 0, SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
                for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            }
            return Data(bytes).base64EncodedString()
        }
        let storageGet: @convention(block) (JSValue) -> JSValue = { [weak self] key in
            let context = JSContext.current()
            guard let self, let value = self.loadedStorage()[key.toString() ?? ""] else {
                return JSValue(nullIn: context)
            }
            return JSValue(object: value, in: context)
        }
        let storageSet: @convention(block) (JSValue, JSValue) -> Bool = { [weak self] key, value in
            self?.storageSet(key.toString() ?? "", value.toString() ?? "") ?? false
        }
        let storageRemove: @convention(block) (JSValue) -> Void = { [weak self] key in
            _ = self?.storageSet(key.toString() ?? "", nil)
        }
        let storageClear: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            self.storage = [:]
            self.storageBytes = 0
            self.storageDirty = true
        }
        let storageKeys: @convention(block) () -> [String] = { [weak self] in
            self?.loadedStorage().keys.sorted() ?? []
        }
        let settingsSave: @convention(block) (JSValue) -> Bool = { [weak self] json in
            guard let self,
                  let data = (json.toString() ?? "").data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return PluginSettingsVault.save(object, scraperID: self.scraperId, profileScope: self.storageScope)
        }
        let fileRead: @convention(block) (JSValue) -> JSValue = { [weak self] name in
            let context = JSContext.current()
            guard let self, let text = self.files.read(name.toString() ?? "") else { return JSValue(nullIn: context) }
            return JSValue(object: text, in: context)
        }
        let fileWrite: @convention(block) (JSValue, JSValue) -> Bool = { [weak self] name, text in
            self?.files.write(name.toString() ?? "", text.toString() ?? "") ?? false
        }
        let fileRemove: @convention(block) (JSValue) -> Void = { [weak self] name in
            self?.files.remove(name.toString() ?? "")
        }
        let fileList: @convention(block) () -> [String] = { [weak self] in
            self?.files.names() ?? []
        }
        let fileUsage: @convention(block) () -> Int = { [weak self] in
            self?.files.usage() ?? 0
        }
        let routeURL: @convention(block) (JSValue) -> String = { [weak self] path in
            guard let self else { return "" }
            PluginLoopbackServer.shared.ensureRunning()
            return PluginLoopbackServer.shared.routeURL(scraperID: self.scraperId, path: path.toString() ?? "")
        }
        let emit: @convention(block) (JSValue, JSValue) -> Void = { [weak self] callID, json in
            guard let self else { return }
            let id = Int(callID.toInt32())
            self.lock.lock()
            let handler = self.calls[id]?.onEmit
            self.lock.unlock()
            handler?(json.toString() ?? "[]")
        }
        let done: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] json, error, callID in
            guard let self else { return }
            let id = Int(callID.toInt32())
            if !error.isNull, !error.isUndefined {
                let message = error.toString() ?? "The plugin failed."
                if message == "__missing__" {
                    self.lock.lock()
                    let function = self.calls[id]?.function ?? ""
                    self.lock.unlock()
                    self.finish(id, .failure(PluginRuntimeError.missingFunction(function)))
                } else {
                    self.finish(id, .failure(PluginRuntimeError.script(message)))
                }
                return
            }
            let text = (json.isNull || json.isUndefined) ? "null" : (json.toString() ?? "null")
            let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? NSNull()
            self.finish(id, .success(value))
        }

        let natives: [(String, AnyObject)] = [
            ("log", unsafeBitCast(log, to: AnyObject.self)),
            ("setTimer", unsafeBitCast(setTimer, to: AnyObject.self)),
            ("clearTimer", unsafeBitCast(clearTimer, to: AnyObject.self)),
            ("fetch", unsafeBitCast(fetch, to: AnyObject.self)),
            ("abortFetch", unsafeBitCast(abortFetch, to: AnyObject.self)),
            ("digest", unsafeBitCast(digest, to: AnyObject.self)),
            ("hmac", unsafeBitCast(hmac, to: AnyObject.self)),
            ("randomBytes", unsafeBitCast(randomBytes, to: AnyObject.self)),
            ("storageGet", unsafeBitCast(storageGet, to: AnyObject.self)),
            ("storageSet", unsafeBitCast(storageSet, to: AnyObject.self)),
            ("storageRemove", unsafeBitCast(storageRemove, to: AnyObject.self)),
            ("storageClear", unsafeBitCast(storageClear, to: AnyObject.self)),
            ("storageKeys", unsafeBitCast(storageKeys, to: AnyObject.self)),
            ("settingsSave", unsafeBitCast(settingsSave, to: AnyObject.self)),
            ("fileRead", unsafeBitCast(fileRead, to: AnyObject.self)),
            ("fileWrite", unsafeBitCast(fileWrite, to: AnyObject.self)),
            ("fileRemove", unsafeBitCast(fileRemove, to: AnyObject.self)),
            ("fileList", unsafeBitCast(fileList, to: AnyObject.self)),
            ("fileUsage", unsafeBitCast(fileUsage, to: AnyObject.self)),
            ("routeURL", unsafeBitCast(routeURL, to: AnyObject.self)),
            ("emit", unsafeBitCast(emit, to: AnyObject.self)),
            ("done", unsafeBitCast(done, to: AnyObject.self))
        ]
        for (name, block) in natives {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }
        PluginCompatNatives.install(on: native, dom: dom)
        context.setObject(native, forKeyedSubscript: "__nuvioNative" as NSString)
    }

    private func loadedStorage() -> [String: String] {
        if let storage { return storage }
        let loaded = PluginStorageFile.load(scraperID: scraperId, scope: storageScope)
        storage = loaded
        storageBytes = loaded.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        return loaded
    }

    /// Sets (or with nil removes) one `localStorage` item; false when the
    /// plugin's storage would grow past its limit.
    @discardableResult
    private func storageSet(_ key: String, _ value: String?) -> Bool {
        var current = loadedStorage()
        let oldSize = current[key].map { key.utf8.count + $0.utf8.count } ?? 0
        let newSize = value.map { key.utf8.count + $0.utf8.count } ?? 0
        if value != nil, storageBytes - oldSize + newSize > PluginStorageFile.maxBytes { return false }
        current[key] = value
        storage = current
        storageBytes += newSize - oldSize
        storageDirty = true
        return true
    }

    private func setTimer(_ id: Int, milliseconds: Double) {
        timers[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let context = self.context else { return }
            self.timers[id] = nil
            context.objectForKeyedSubscript("__nuvioTimerFired")?.call(withArguments: [id])
        }
        timers[id] = item
        queue.asyncAfter(deadline: .now() + milliseconds / 1_000, execute: item)
    }

    private func startFetch(id: Int, url rawURL: String, optionsJSON: String) {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            deliverFetch(id, ["error": "Unsupported URL: \(rawURL)"])
            return
        }
        let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any] ?? [:]
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String)?.uppercased() ?? "GET"
        var hasUserAgent = false
        for (name, value) in (options["headers"] as? [String: Any]) ?? [:] {
            request.setValue("\(value)", forHTTPHeaderField: name)
            if name.caseInsensitiveCompare("User-Agent") == .orderedSame { hasUserAgent = true }
        }
        if !hasUserAgent {
            request.setValue(PluginRuntime.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let body = options["body"] as? String {
            request.httpBody = Data(body.utf8)
        } else if let base64 = options["bodyBase64"] as? String {
            request.httpBody = Data(base64Encoded: base64)
        }

        let method = request.httpMethod ?? "GET"
        let started = Date()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            PluginNetworkLog.record(
                scraperId: self.scraperId,
                method: method,
                url: url,
                response: response,
                bytes: data?.count ?? 0,
                error: error,
                since: started
            )
            self.queue.async {
                // Gone when the script aborted it or the context was released.
                guard self.tasks.removeValue(forKey: id) != nil else { return }
                self.deliverFetch(id, PluginInstance.fetchPayload(data: data, response: response, error: error, requestedURL: url))
            }
        }
        if (options["redirect"] as? String)?.lowercased() == "manual" {
            task.delegate = PluginNoRedirectDelegate.shared
        }
        tasks[id] = task
        task.resume()
    }

    private func deliverFetch(_ id: Int, _ payload: [String: Any]) {
        guard let context else { return }
        let json = PluginRuntime.jsonLiteral(payload) ?? "{\"error\":\"The response could not be read.\"}"
        context.objectForKeyedSubscript("__nuvioFetchDone")?.call(withArguments: [id, json])
    }

    static func fetchPayload(data: Data?, response: URLResponse?, error: Error?, requestedURL: URL) -> [String: Any] {
        if let error {
            return ["error": (error as NSError).localizedDescription]
        }
        guard let http = response as? HTTPURLResponse else {
            return ["error": "No response from the server."]
        }
        let body = data ?? Data()
        guard body.count <= PluginRuntime.maxResponseBytes else {
            return ["error": "The response is larger than \(PluginRuntime.maxResponseBytes / 1_048_576) MB."]
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var payload: [String: Any] = [
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "headers": headers,
            "url": http.url?.absoluteString ?? requestedURL.absoluteString,
            "redirected": (http.url.map { $0 != requestedURL }) ?? false
        ]
        if let text = String(data: body, encoding: .utf8) {
            payload["text"] = text
        } else {
            payload["base64"] = body.base64EncodedString()
        }
        return payload
    }

    static func digest(_ algorithm: String, _ data: Data) -> Data? {
        switch algorithm {
        case "SHA-1": return Data(Insecure.SHA1.hash(data: data))
        case "SHA-256": return Data(SHA256.hash(data: data))
        case "SHA-384": return Data(SHA384.hash(data: data))
        case "SHA-512": return Data(SHA512.hash(data: data))
        case "MD5": return Data(Insecure.MD5.hash(data: data))
        default: return nil
        }
    }

    static func hmac(_ algorithm: String, key: Data, data: Data) -> Data? {
        let symmetricKey = SymmetricKey(data: key)
        switch algorithm {
        case "SHA-1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey))
        case "SHA-256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey))
        case "SHA-384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: symmetricKey))
        case "SHA-512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey))
        case "MD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: symmetricKey))
        default: return nil
        }
    }
}

/// Network lines in a provider's log: method, URL with secrets masked,
/// status, time and size.
enum PluginNetworkLog {
    private static let secretNames: Set<String> = [
        "apikey", "api_key", "key", "token", "access_token", "refresh_token", "auth", "authorization",
        "password", "pass", "passwd", "pwd", "secret", "client_secret", "sig", "signature",
        "session", "sessionid", "sid", "wst", "cookie", "hash", "passkey", "uid"
    ]

    static func record(
        scraperId: String,
        method: String,
        url: URL,
        response: URLResponse?,
        bytes: Int,
        error: Error?,
        since started: Date
    ) {
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        var text = "\(method) \(redact(url)) → "
        if let error {
            text += "✕ \((error as NSError).localizedDescription) · \(milliseconds) ms"
        } else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            text += "\(status) · \(milliseconds) ms · \(formatBytes(bytes))"
        }
        PluginLogStore.shared.append(scraperId, level: .net, message: text)
    }

    /// The URL without credentials: user info is dropped, secret-looking
    /// query values and long key-like path segments become `••••`.
    static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
        components.user = nil
        components.password = nil
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                let name = item.name.lowercased()
                let secret = secretNames.contains(name) || name.hasSuffix("key") || name.hasSuffix("token")
                return secret && !(item.value ?? "").isEmpty ? URLQueryItem(name: item.name, value: "••••") : item
            }
        }
        // The path setter takes percent-encoded text only: "••••" encoded.
        let mask = String(repeating: "%E2%80%A2", count: 4)
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let text = String(segment)
            if let equals = text.firstIndex(of: "="), text.distance(from: equals, to: text.endIndex) > 12 {
                return String(text[...equals]) + mask
            }
            if text.count >= 24, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
                return mask
            }
            return text
        }
        components.percentEncodedPath = segments.joined(separator: "/")
        let string = (components.string ?? "<url>").replacingOccurrences(of: "%E2%80%A2", with: "•")
        return string.count > 300 ? String(string.prefix(300)) + "…" : string
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.0f KB", Double(bytes) / 1_024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// `redirect: 'manual'`: hand the 3xx response (and its Location) to the script.
final class PluginNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = PluginNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Storage

/// A plugin's `localStorage`, per scraper and profile, kept in a file on this
/// Apple TV (an Apple TV extension; the system may purge it like any cache).
enum PluginStorageFile {
    static let maxBytes = 5 * 1024 * 1024
    private static let directory = "NuvioPlugins"

    static func load(scraperID: String, scope: String) -> [String: String] {
        guard let data = LargePayloadStore.read(key: key(scraperID, scope), directory: directory),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    static func save(_ storage: [String: String], scraperID: String, scope: String) {
        if storage.isEmpty {
            remove(scraperID: scraperID, scope: scope)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: storage) else { return }
        LargePayloadStore.write(data, key: key(scraperID, scope), directory: directory)
    }

    static func remove(scraperID: String, scope: String) {
        LargePayloadStore.remove(key: key(scraperID, scope), directory: directory)
    }

    private static func key(_ scraperID: String, _ scope: String) -> String {
        let digest = SHA256.hash(data: Data(scraperID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(scope).storage.\(digest)"
    }
}

// MARK: - Logs

enum PluginLogLevel: String, Sendable {
    case log, info, debug, warn, error
    /// Requests and call times (``PluginNetworkLog``).
    case net
}

struct PluginLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let level: PluginLogLevel
    let message: String
}

/// The last few hundred console lines per scraper, shown in Settings so a
/// plugin author (or the user) can see why a plugin found nothing.
final class PluginLogStore: @unchecked Sendable {
    static let shared = PluginLogStore()
    static let limit = 300
    private static let maxMessageLength = 4_000

    private let lock = NSLock()
    private var entries: [String: [PluginLogEntry]] = [:]

    func append(_ scraperId: String, level: PluginLogLevel, message: String) {
        let text = message.count > Self.maxMessageLength
            ? String(message.prefix(Self.maxMessageLength)) + "…"
            : message
        lock.lock()
        var list = entries[scraperId] ?? []
        list.append(PluginLogEntry(date: Date(), level: level, message: text))
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        entries[scraperId] = list
        lock.unlock()
        #if DEBUG
        print("[Plugin] \(level.rawValue): \(text.prefix(300))")
        #endif
    }

    func entries(for scraperId: String) -> [PluginLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries[scraperId] ?? []
    }

    func clear(_ scraperId: String) {
        lock.lock()
        entries[scraperId] = nil
        lock.unlock()
    }
}
