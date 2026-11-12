//
//  NuvioFormatting.swift
//  NuvioTV
//
//  Created for NuvioTVOS modularization.
//

import Foundation

enum NuvioDateDisplay {
    /// Formatted dates by input. Cards and episode rows format their dates every time they
    /// redraw, and each formatting goes through ICU (seen in main-thread samples on an Apple
    /// TV); the same few dates come back again and again.
    private static let formatted = NSCache<NSString, NSString>()

    static func formattedDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let fullDates = showsFullDates
        let cacheKey = ((fullDates ? "f\u{1}" : "y\u{1}") + value) as NSString
        if let cached = formatted.object(forKey: cacheKey) { return cached as String }
        guard let result = format(value, fullDates: fullDates) else { return nil }
        formatted.setObject(result as NSString, forKey: cacheKey)
        return result
    }

    private static func format(_ value: String, fullDates: Bool) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return nil
        }
        if raw.caseInsensitiveCompare("tbd") == .orderedSame || raw.caseInsensitiveCompare("tba") == .orderedSame {
            return "TBD"
        }

        let datePart = String(raw.prefix(10))
        if !fullDates {
            let year = String(datePart.prefix(4))
            return Int(year) == nil ? raw : year
        }
        guard datePart.count == 10,
              let date = isoDay.date(from: datePart) else {
            return raw
        }

        return display.string(from: date)
    }

    private static var showsFullDates: Bool {
        let key = "nuvio.tv.settings.layout.showFullDates"
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()
}

/// Formats Stremio/Cinemeta runtime strings ("142 min", "120", "1h 55min")
/// into hour/minute display ("2h 22m", "2h", "45m").
enum NuvioRuntimeDisplay {
    static func formatted(_ runtime: String?) -> String? {
        guard let runtime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runtime.isEmpty else {
            return nil
        }

        let normalized = runtime.lowercased()
        let hours = firstNumber(in: normalized, pattern: #"(\d+)\s*h"#)
        let minutes = firstNumber(in: normalized, pattern: #"(\d+)\s*m(?:in)?"#)
        let totalMinutes: Int?

        if hours != nil || minutes != nil {
            totalMinutes = (hours ?? 0) * 60 + (minutes ?? 0)
        } else {
            totalMinutes = Int(normalized.filter(\.isNumber))
        }

        guard let totalMinutes, totalMinutes > 0 else {
            return runtime
        }

        let wholeHours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60

        if wholeHours > 0 && remainingMinutes > 0 {
            return "\(wholeHours)h \(remainingMinutes)m"
        } else if wholeHours > 0 {
            return "\(wholeHours)h"
        } else {
            return "\(remainingMinutes)m"
        }
    }

    private static func firstNumber(in value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[range])
    }
}
