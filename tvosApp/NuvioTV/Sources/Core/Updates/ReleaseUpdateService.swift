import Foundation
import Combine

struct NumericReleaseVersion: Comparable, Equatable {
    let components: [UInt64]

    init?(tag: String) {
        var version = tag
        for prefix in ["tvos-beta-", "tvos-", "v"] where version.hasPrefix(prefix) {
            version.removeFirst(prefix.count)
            break
        }

        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var components: [UInt64] = []
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt64(part) else { return nil }
            components.append(value)
        }
        self.components = components
    }

    var displayValue: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct ReleaseUpdateMetadata: Codable, Equatable, Identifiable {
    let tagName: String
    let releaseURL: URL

    var id: String { tagName }
    var version: NumericReleaseVersion { NumericReleaseVersion(tag: tagName)! }
    var displayVersion: String { version.displayValue }

    init?(tagName: String, releaseURLString: String) {
        guard NumericReleaseVersion(tag: tagName) != nil,
              let url = URL(string: releaseURLString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/\(AppRepository.slug)/releases/tag/\(tagName)" else {
            return nil
        }
        self.tagName = tagName
        self.releaseURL = url
    }
}

@MainActor
final class ReleaseUpdateService: ObservableObject {
    static let enabledKey = "releaseUpdatesEnabled"
    static let lastAttemptKey = "releaseUpdatesLastAttempt"
    static let cachedReleaseKey = "releaseUpdatesCachedRelease"
    static let skippedTagKey = "releaseUpdatesSkippedTag"
    static let latestReleaseEndpoint = URL(string: "https://api.github.com/repos/\(AppRepository.slug)/releases/latest")!

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let prerelease: Bool
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case prerelease
            case draft
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var latestRelease: ReleaseUpdateMetadata?

    private let defaults: UserDefaults
    private let session: URLSession
    private let now: () -> Date
    private let runningVersion: NumericReleaseVersion?
    private var inFlightTask: Task<Void, Never>?
    private var inFlightID: UUID?
    @Published private var dismissedTag: String?

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        runningVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    ) {
        self.defaults = defaults
        self.session = session
        self.now = now
        self.runningVersion = NumericReleaseVersion(tag: runningVersion)
        isEnabled = (defaults.object(forKey: Self.enabledKey) as? Bool) ?? true
        latestRelease = Self.cachedRelease(in: defaults)
    }

    var isUpdateAvailable: Bool {
        guard let latestRelease, let runningVersion else { return false }
        return latestRelease.version > runningVersion
    }

    var shouldShowNotice: Bool {
        guard isEnabled, isUpdateAvailable, let latestRelease else { return false }
        let skippedTag = defaults.string(forKey: Self.skippedTagKey)
        return latestRelease.tagName != skippedTag && latestRelease.tagName != dismissedTag
    }

    var latestStatus: String {
        guard let latestRelease else {
            if !isEnabled { return "Checks off" }
            return isChecking ? "Checking for updates…" : "No release information available"
        }
        let status = !isEnabled
            ? "Checks off"
            : isChecking
                ? "Checking…"
                : isUpdateAvailable ? "Available" : "Up to date"
        return "\(latestRelease.displayVersion) · \(status)"
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)

        guard !enabled else { return }
        inFlightID = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        isChecking = false
    }

    /// `force` is Settings → Check Now: it skips the once-a-day limit.
    func checkIfNeeded(force: Bool = false) async {
        guard isEnabled else { return }
        if let inFlightTask {
            await inFlightTask.value
            return
        }

        let attemptDate = now()
        if !force,
           let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date,
           attemptDate.timeIntervalSince(lastAttempt) < 24 * 60 * 60 {
            return
        }

        // Persist before starting the request so failures and rate limits are throttled too.
        defaults.set(attemptDate, forKey: Self.lastAttemptKey)
        let requestID = UUID()
        inFlightID = requestID
        isChecking = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCheck(requestID: requestID)
        }
        inFlightTask = task
        await task.value
    }

    func dismissNotice() {
        guard let latestRelease else { return }
        dismissNotice(tag: latestRelease.tagName)
    }

    func dismissNotice(tag: String) {
        dismissedTag = tag
    }

    func beginForegroundSession() {
        dismissedTag = nil
    }

    func skipCurrentVersion() {
        guard let latestRelease else { return }
        skipCurrentVersion(tag: latestRelease.tagName)
    }

    func skipCurrentVersion(tag: String) {
        defaults.set(tag, forKey: Self.skippedTagKey)
        dismissedTag = tag
    }

    private func performCheck(requestID: UUID) async {
        var request = URLRequest(url: Self.latestReleaseEndpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NuvioTV", forHTTPHeaderField: "User-Agent")

        var validatedRelease: ReleaseUpdateMetadata?
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  !release.prerelease,
                  !release.draft else {
                finishCheck(requestID: requestID)
                return
            }
            validatedRelease = ReleaseUpdateMetadata(tagName: release.tagName, releaseURLString: release.htmlURL)
        } catch {
            finishCheck(requestID: requestID)
            return
        }

        guard !Task.isCancelled, isEnabled, inFlightID == requestID else {
            finishCheck(requestID: requestID)
            return
        }
        guard let validatedRelease else {
            finishCheck(requestID: requestID)
            return
        }

        latestRelease = validatedRelease
        if let data = try? JSONEncoder().encode(validatedRelease) {
            defaults.set(data, forKey: Self.cachedReleaseKey)
        }
        finishCheck(requestID: requestID)
    }

    private func finishCheck(requestID: UUID) {
        guard inFlightID == requestID else { return }
        isChecking = false
        inFlightID = nil
        inFlightTask = nil
    }

    private static func cachedRelease(in defaults: UserDefaults) -> ReleaseUpdateMetadata? {
        guard let data = defaults.data(forKey: cachedReleaseKey),
              let cached = try? JSONDecoder().decode(ReleaseUpdateMetadata.self, from: data) else {
            return nil
        }
        return ReleaseUpdateMetadata(tagName: cached.tagName, releaseURLString: cached.releaseURL.absoluteString)
    }
}
