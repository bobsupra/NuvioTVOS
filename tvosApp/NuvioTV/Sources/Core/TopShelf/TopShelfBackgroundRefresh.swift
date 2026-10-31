import BackgroundTasks
import Foundation

// App-only: keeps the Top Shelf's Home catalogs fresh while Nuvio isn't open.
//
// The shelf shows the copy of Home's catalogs the app last wrote, and nothing
// tells the app or the extension when the Apple TV wakes up. tvOS does run apps
// in the background now and then (BGAppRefreshTask; when and how often is the
// system's choice, guided by how much the app is used), so each run loads
// Home's catalogs as Home does and mirrors them to the shelf.

enum TopShelfBackgroundRefresh {
    /// Listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let taskIdentifier = "com.nuvio.tv.topshelf.refresh"
    /// The earliest the system may run the next refresh after scheduling one.
    static let interval: TimeInterval = 60 * 60

    /// The last run, for Settings: when, how many catalog rows it brought,
    /// and whether it finished before the system's time limit.
    struct Status: Codable, Equatable {
        let date: Date
        let rows: Int
        let complete: Bool
    }

    private static let statusKey = "topShelf.backgroundRefresh.last"
    private static var isRegistered = false

    static var lastStatus: Status? {
        guard let data = UserDefaults.standard.data(forKey: statusKey) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    /// Called once from the app's init: BGTaskScheduler only accepts handlers
    /// registered before launch finishes.
    static func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task)
        }
        schedule()
    }

    /// Asks for the next run. A new request replaces the pending one.
    static func schedule() {
        guard isRegistered, TopShelfFeedStore.isAvailable else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        schedule()
        let work = Task { @MainActor in await refresh() }
        task.expirationHandler = { work.cancel() }
        Task {
            let complete = await work.value
            task.setTaskCompleted(success: complete)
        }
    }

    /// Loads Home's catalogs and writes them to the shelf. True when every
    /// catalog arrived in time.
    @MainActor
    @discardableResult
    static func refresh() async -> Bool {
        guard TopShelfFeedStore.isAvailable else { return false }
        // Launched in the background, nothing has loaded the profile yet:
        // the last active one, as the app's own launch picks it.
        if ProfileSettings.activeProfileID == nil {
            _ = ProfileViewModel()
        }
        guard ProfileSettings.activeProfileID != nil else {
            record(rows: 0, complete: false)
            return false
        }

        let repository = CinemetaCatalogRepository()
        var built: [String: TVHomeSection] = [:]
        var order: [String] = []
        var complete = false
        do {
            // Each yield is every row so far; only the new ones are built.
            for try await catalogs in repository.homeCatalogsProgressively() {
                try Task.checkCancellation()
                let fresh = catalogs.filter { built[$0.id] == nil }
                for section in await TVHomeView.makeHomeCatalogSections(from: fresh, repository: repository) {
                    built[section.id] = section
                }
                order = catalogs.map(\.id)
            }
            complete = !Task.isCancelled
        } catch {
            complete = false
        }

        let refreshed = TVHomeStore.topShelfCatalogRows(
            from: TVHomeCatalogOrder.apply(to: order.compactMap { built[$0] }))
        let previous = TopShelfFeedStore.read(.catalog)?.catalogRows ?? []
        let rows = merged(refreshed: refreshed, previous: previous, complete: complete)
        guard !refreshed.isEmpty, !rows.isEmpty else {
            record(rows: 0, complete: false)
            return false
        }
        if Task.isCancelled {
            // Out of time: save the rows, the artwork follows on the next run.
            TopShelfFeedStore.writeCatalogRows(rows)
        } else {
            await TopShelfFeedStore.writeCatalogRowsAndWait(rows)
        }
        record(rows: refreshed.count, complete: complete)
        return complete
    }

    /// The rows to write. Every catalog arrived: Home's rows as they are now.
    /// Cut short: each row that arrived replaces its old copy, the others
    /// stay as they were until the next run, and new ones go last.
    static func merged(
        refreshed: [TopShelfFeedRow],
        previous: [TopShelfFeedRow],
        complete: Bool
    ) -> [TopShelfFeedRow] {
        if complete, !refreshed.isEmpty { return refreshed }
        let refreshedByID = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousIDs = Set(previous.map(\.id))
        return previous.map { refreshedByID[$0.id] ?? $0 } + refreshed.filter { !previousIDs.contains($0.id) }
    }

    private static func record(rows: Int, complete: Bool) {
        let status = Status(date: Date(), rows: rows, complete: complete)
        guard let data = try? JSONEncoder().encode(status) else { return }
        UserDefaults.standard.set(data, forKey: statusKey)
    }
}
