import Foundation
import Combine

struct Announcement: Equatable, Identifiable {
    let id: String
    let title: String
    let message: String
    let linkURL: URL?
    let startsAt: Date?
    let endsAt: Date?

    func isActive(at date: Date) -> Bool {
        (startsAt == nil || date >= startsAt!)
            && (endsAt == nil || date < endsAt!)
    }
}

@MainActor
final class AnnouncementService: ObservableObject {
    static let enabledKey = "announcementsEnabled"
    static let lastAttemptKey = "announcementsLastAttempt"
    static let cachedFeedKey = "announcementsCachedFeed"
    static let skippedIDsKey = "announcementSkippedIDs"
    static let feedEndpoint = URL(string: "https://raw.githubusercontent.com/\(AppRepository.slug)/main/announcements.json")!

    private static let throttleInterval: TimeInterval = 60 * 60
    private static let maximumFeedBytes = 64 * 1024
    private static let maximumAnnouncements = 10

    private struct FeedPayload: Decodable {
        let schemaVersion: Int
        let announcements: [AnnouncementPayload]
    }

    private struct AnnouncementPayload: Decodable {
        let id: String
        let title: String
        let message: String
        let linkURL: String?
        let startsAt: String?
        let endsAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case message
            case linkURL
            case startsAt
            case endsAt
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var activeAnnouncements: [Announcement] = []
    @Published private var dismissedIDs: Set<String> = []

    private let defaults: UserDefaults
    private let session: URLSession
    private let now: () -> Date
    private var allAnnouncements: [Announcement]
    private var hasLoadedFeed: Bool
    private var inFlightTask: Task<Void, Never>?
    private var inFlightID: UUID?
    private var boundaryTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.session = session
        self.now = now
        isEnabled = (defaults.object(forKey: Self.enabledKey) as? Bool) ?? true

        if let cached = Self.validatedCachedFeed(in: defaults) {
            allAnnouncements = cached
            hasLoadedFeed = true
        } else {
            allAnnouncements = []
            hasLoadedFeed = false
        }
        reevaluateAvailability()
    }

    var dismissedAnnouncementIDs: Set<String> { dismissedIDs }

    var skippedAnnouncementIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.skippedIDsKey) ?? [])
    }

    var firstAvailableAnnouncement: Announcement? {
        guard isEnabled else { return nil }
        return activeAnnouncements.first { !skippedAnnouncementIDs.contains($0.id) && !dismissedIDs.contains($0.id) }
    }

    var firstActiveAnnouncement: Announcement? {
        activeAnnouncements.first
    }

    var status: String {
        let count = activeAnnouncements.count
        if !isEnabled {
            return count == 0 ? "Checks off" : "Checks off · \(count) active"
        }
        if isChecking {
            return count == 0 ? "Checking for messages…" : "\(count) active · Checking…"
        }
        guard hasLoadedFeed else { return "No cached messages" }
        guard count > 0 else { return "No active messages" }
        return count == 1 ? "1 active message" : "\(count) active messages"
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)

        if enabled {
            reevaluateAvailability()
        } else {
            inFlightID = nil
            inFlightTask?.cancel()
            inFlightTask = nil
            isChecking = false
        }
    }

    func checkIfNeeded() async {
        guard isEnabled else { return }
        if let inFlightTask {
            await inFlightTask.value
            return
        }

        let attemptDate = now()
        if let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date,
           attemptDate.timeIntervalSince(lastAttempt) < Self.throttleInterval {
            reevaluateAvailability()
            return
        }

        // Persist before starting so failures and rate limits also consume the hour window.
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

    func beginForegroundSession() {
        dismissedIDs = []
        reevaluateAvailability()
    }

    func dismiss(id: String) {
        guard allAnnouncements.contains(where: { $0.id == id }) else { return }
        dismissedIDs.insert(id)
    }

    func skip(id: String) {
        guard allAnnouncements.contains(where: { $0.id == id }) else { return }
        var skipped = skippedAnnouncementIDs
        skipped.insert(id)
        defaults.set(skipped.sorted(), forKey: Self.skippedIDsKey)
        dismissedIDs.insert(id)
    }

    private func performCheck(requestID: UUID) async {
        var request = URLRequest(url: Self.feedEndpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NuvioTV", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let validated = Self.validatedFeed(from: data) else {
                finishCheck(requestID: requestID)
                return
            }

            guard isEnabled, inFlightID == requestID else {
                finishCheck(requestID: requestID)
                return
            }

            allAnnouncements = validated
            hasLoadedFeed = true
            if validated.isEmpty {
                defaults.removeObject(forKey: Self.cachedFeedKey)
            } else {
                defaults.set(data, forKey: Self.cachedFeedKey)
            }
            reevaluateAvailability()
            finishCheck(requestID: requestID)
        } catch {
            finishCheck(requestID: requestID)
        }
    }

    private func finishCheck(requestID: UUID) {
        guard inFlightID == requestID else { return }
        isChecking = false
        inFlightID = nil
        inFlightTask = nil
    }

    private func reevaluateAvailability() {
        let currentTime = now()
        activeAnnouncements = allAnnouncements.filter { $0.isActive(at: currentTime) }
        scheduleNextBoundary(after: currentTime)
    }

    private func scheduleNextBoundary(after currentTime: Date) {
        boundaryTask?.cancel()
        let nextBoundary = allAnnouncements
            .flatMap { [$0.startsAt, $0.endsAt] }
            .compactMap { $0 }
            .filter { $0 > currentTime }
            .min()
        guard let nextBoundary else { return }

        let seconds = max(0, nextBoundary.timeIntervalSince(currentTime))
        let nanoseconds = seconds >= Double(UInt64.max) / 1_000_000_000
            ? UInt64.max
            : UInt64(seconds * 1_000_000_000)
        boundaryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.reevaluateAvailability()
        }
    }

    private static func validatedCachedFeed(in defaults: UserDefaults) -> [Announcement]? {
        guard let data = defaults.data(forKey: cachedFeedKey) else { return nil }
        guard let feed = validatedFeed(from: data) else {
            defaults.removeObject(forKey: cachedFeedKey)
            return nil
        }
        return feed
    }

    private static func validatedFeed(from data: Data) -> [Announcement]? {
        guard data.count <= maximumFeedBytes,
              let payload = try? JSONDecoder().decode(FeedPayload.self, from: data),
              payload.schemaVersion == 1,
              payload.announcements.count <= maximumAnnouncements else {
            return nil
        }

        var seenIDs = Set<String>()
        var validated: [Announcement] = []
        validated.reserveCapacity(payload.announcements.count)
        for item in payload.announcements {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = item.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidID(item.id), seenIDs.insert(item.id).inserted,
                  !title.isEmpty,
                  title.count <= 80,
                  !message.isEmpty,
                  message.count <= 240 else {
                return nil
            }

            let linkURL: URL?
            if let link = item.linkURL {
                guard let validatedURL = validatedHTTPSURL(link) else { return nil }
                linkURL = validatedURL
            } else {
                linkURL = nil
            }

            let startsAt: Date?
            if let value = item.startsAt {
                guard let date = parseUTCDate(value) else { return nil }
                startsAt = date
            } else {
                startsAt = nil
            }

            let endsAt: Date?
            if let value = item.endsAt {
                guard let date = parseUTCDate(value) else { return nil }
                endsAt = date
            } else {
                endsAt = nil
            }

            if let startsAt, let endsAt, startsAt >= endsAt { return nil }
            validated.append(Announcement(
                id: item.id,
                title: title,
                message: message,
                linkURL: linkURL,
                startsAt: startsAt,
                endsAt: endsAt
            ))
        }
        return validated
    }

    private static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 80 else { return false }
        return id.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 45 || byte == 95 || byte == 46
        }
    }

    private static func validatedHTTPSURL(_ value: String) -> URL? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return url
    }

    private static func parseUTCDate(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              bytes.last == 90 else {
            return nil
        }

        let fractionalDigits: Range<Int>
        if bytes.count == 20 {
            fractionalDigits = 20..<20
        } else {
            guard bytes[19] == 46 else { return nil }
            let end = bytes.count - 1
            guard (1...9).contains(end - 20) else { return nil }
            fractionalDigits = 20..<end
            guard bytes[fractionalDigits].allSatisfy(isASCIIDigit) else { return nil }
        }

        guard let year = integer(in: 0..<4, bytes: bytes),
              let month = integer(in: 5..<7, bytes: bytes),
              let day = integer(in: 8..<10, bytes: bytes),
              let hour = integer(in: 11..<13, bytes: bytes),
              let minute = integer(in: 14..<16, bytes: bytes),
              let second = integer(in: 17..<19, bytes: bytes),
              year > 0,
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let baseDate = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: baseDate)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == second else {
            return nil
        }

        let fraction = fractionalDigits.isEmpty
            ? 0
            : Double("0." + String(decoding: bytes[fractionalDigits], as: UTF8.self)) ?? 0
        return baseDate.addingTimeInterval(fraction)
    }

    private static func integer(in range: Range<Int>, bytes: [UInt8]) -> Int? {
        guard bytes[range].allSatisfy(isASCIIDigit) else { return nil }
        return bytes[range].reduce(0) { $0 * 10 + Int($1 - 48) }
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}
