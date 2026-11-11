import Foundation

enum IPTVChannelFilter {
    static func matches(name: String, group: String?, query: String, selectedGroup: String?) -> Bool {
        if let selectedGroup, group != selectedGroup { return false }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || name.localizedStandardContains(term)
    }

    static func groups(in channels: [IPTVChannel]) -> [String] {
        Set(channels.compactMap(\.group)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
