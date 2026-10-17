import Foundation
import SwiftUI
import Combine

enum SidebarClockFormat: String, CaseIterable {
    case automatic = "Automatic"
    case twelveHour = "12 hours"
    case twentyFourHour = "24 hours"

    static func fromStored(_ value: String) -> Self {
        Self(rawValue: value) ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic:
            return L10n.string("sidebar_clock_format_auto", fallback: "Automatic")
        case .twelveHour:
            return L10n.string("sidebar_clock_format_12h", fallback: "12 hours")
        case .twentyFourHour:
            return L10n.string("sidebar_clock_format_24h", fallback: "24 hours")
        }
    }

    func formatter(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        if self == .automatic {
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            // POSIX prevents the device's preferred hour cycle from rewriting
            // an explicit 12/24-hour choice. Explicit 12-hour mode uses AM/PM.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = self == .twelveHour ? "h:mm a" : "HH:mm"
        }
        return formatter
    }

    static func secondsUntilNextMinute(after date: Date) -> TimeInterval {
        let seconds = date.timeIntervalSince1970
        return max(0.05, min(60, (floor(seconds / 60) + 1) * 60 - seconds))
    }
}

@MainActor
private final class SidebarClockModel: ObservableObject {
    @Published private(set) var text = ""
    private var format: SidebarClockFormat = .automatic
    private var formatter = SidebarClockFormat.automatic.formatter()

    func refreshConfiguration() {
        formatter = format.formatter()
        refresh()
    }

    private func refresh() {
        let value = formatter.string(from: Date())
        if value != text { text = value }
    }

    func run(format: SidebarClockFormat) async {
        self.format = format
        refreshConfiguration()
        while !Task.isCancelled {
            let seconds = SidebarClockFormat.secondsUntilNextMinute(after: Date())
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            refresh()
        }
    }
}

/// Mounted only in the native tvOS 27 sidebar header. The model owns its
/// formatter, keeping formatting and minute updates out of the tab shell.
@available(tvOS 27.0, *)
struct TVSidebarClock: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.sidebarClockFormat) private var format = SidebarClockFormat.automatic.rawValue
    @StateObject private var clock = SidebarClockModel()

    var body: some View {
        Text(clock.text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .allowsHitTesting(false)
            .task(id: "\(format):\(scenePhase)") {
                guard scenePhase == .active else { return }
                await clock.run(format: SidebarClockFormat.fromStored(format))
            }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
                .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
                .receive(on: RunLoop.main)) { _ in
                clock.refreshConfiguration()
            }
    }
}
