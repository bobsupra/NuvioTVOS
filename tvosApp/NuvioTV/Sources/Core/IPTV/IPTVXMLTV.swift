import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct IPTVProgramme: Equatable, Sendable {
    let channelID: String
    let title: String
    let start: Date
    let end: Date
}

enum IPTVXMLTVError: Error, Equatable { case invalidDocument, tooLarge }

/// Reads only programmes relevant to the requested channels and time window.
/// Does not fetch a guide or persist it; callers decide how to handle failure.
enum IPTVXMLTV {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumProgrammes = 100_000
    private static let epgShareChannelIDRegex = try! NSRegularExpression(
        pattern: #"^(.+)\.[^.]+\.\(([A-Z]{2}),[^()]+\)\.([a-z]{2})$"#
    )

    static func parse(
        _ data: Data,
        channelIDs: Set<String>,
        window: Range<Date>,
        allowEPGShareAliases: Bool = false
    ) throws -> [IPTVProgramme] {
        guard data.count <= maximumBytes else { throw IPTVXMLTVError.tooLarge }
        let aliases = allowEPGShareAliases ? channelAliases(for: channelIDs) : [:]
        let reader = Reader(channelIDs: channelIDs, aliases: aliases, window: window)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.sawRoot else {
            if reader.exceededLimit { throw IPTVXMLTVError.tooLarge }
            throw IPTVXMLTVError.invalidDocument
        }
        return reader.programmes.sorted { $0.start < $1.start }
    }

    /// EPGShare-style IDs can append a territory and locale to a station ID.
    /// Only map the anchored `<station>.<territory>.(CC,locale).cc` form when
    /// its country codes agree and exactly one requested channel has that station and country.
    private static func channelAliases(for requested: Set<String>) -> [String: String] {
        var stationTargets: [String: [String]] = [:]
        for channelID in requested {
            guard let separator = channelID.lastIndex(of: ".") else { continue }
            let station = channelID[..<separator]
            let country = channelID[channelID.index(after: separator)...]
            guard !station.isEmpty, country.count == 2, country.allSatisfy(\.isLetter) else { continue }
            let key = normalizedStation(station) + "." + country.lowercased()
            stationTargets[key, default: []].append(channelID)
        }
        return Dictionary(uniqueKeysWithValues: stationTargets.compactMap { station, targets in
            targets.count == 1 ? (station, targets[0]) : nil
        })
    }

    private static func normalizedStation(_ station: some StringProtocol) -> String {
        station.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let channelIDs: Set<String>
        let aliases: [String: String]
        let window: Range<Date>
        var programmes: [IPTVProgramme] = []
        var sawRoot = false
        var exceededLimit = false
        var depth = 0
        var current: (channel: String, start: Date, end: Date)?
        var title = ""
        var readingTitle = false
        let formatter: DateFormatter = {
            let result = DateFormatter()
            result.locale = Locale(identifier: "en_US_POSIX")
            result.timeZone = TimeZone(secondsFromGMT: 0)
            result.dateFormat = "yyyyMMddHHmmss Z"
            result.isLenient = false
            return result
        }()

        init(channelIDs: Set<String>, aliases: [String: String], window: Range<Date>) {
            self.channelIDs = channelIDs
            self.aliases = aliases
            self.window = window
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if Task.isCancelled { parser.abortParsing(); return }
            depth += 1
            if depth == 1 { sawRoot = elementName == "tv" }
            guard sawRoot else { return }
            if elementName == "programme", depth == 2 {
                current = nil
                title = ""
                guard let rawID = attributes["channel"], let id = matchedChannelID(rawID),
                      let rawStart = attributes["start"], let start = parseDate(rawStart),
                      let rawEnd = attributes["stop"], let end = parseDate(rawEnd),
                      start < end, start < window.upperBound, end > window.lowerBound else { return }
                current = (id, start, end)
            } else if elementName == "title", depth == 3, current != nil, title.isEmpty {
                readingTitle = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if readingTitle { title.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "title", depth == 3 { readingTitle = false }
            if elementName == "programme", depth == 2, let entry = current {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    guard programmes.count < IPTVXMLTV.maximumProgrammes else {
                        exceededLimit = true
                        parser.abortParsing()
                        return
                    }
                    programmes.append(IPTVProgramme(channelID: entry.channel, title: trimmed, start: entry.start, end: entry.end))
                }
                current = nil
            }
            depth -= 1
        }

        private func parseDate(_ text: String) -> Date? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // XMLTV timestamps without an offset use UTC.
            return formatter.date(from: value.contains(" ") ? value : value + " +0000")
        }

        private func matchedChannelID(_ rawID: String) -> String? {
            if channelIDs.contains(rawID) { return rawID }
            guard !aliases.isEmpty,
                  let match = IPTVXMLTV.epgShareChannelIDRegex.firstMatch(in: rawID, range: NSRange(rawID.startIndex..., in: rawID)),
                  match.numberOfRanges == 4,
                  let stationRange = Range(match.range(at: 1), in: rawID),
                  let countryRange = Range(match.range(at: 2), in: rawID),
                  let suffixRange = Range(match.range(at: 3), in: rawID) else { return nil }
            let station = IPTVXMLTV.normalizedStation(rawID[stationRange])
            let country = rawID[countryRange]
            let suffix = rawID[suffixRange]
            let key = station + "." + suffix
            guard country.lowercased() == suffix,
                  let target = aliases[key],
                  target.lowercased().hasSuffix("." + suffix) else { return nil }
            return target
        }
    }
}
