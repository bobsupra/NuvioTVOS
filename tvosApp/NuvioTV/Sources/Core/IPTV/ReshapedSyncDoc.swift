import Foundation

/// Version 1 of Reshaped's per-key sync document.
///
/// A missing entry value is a tombstone. JSON `null` remains a valid synced value.
enum ReshapedSyncDoc {
    static let version = 1
    static let tombstoneRetentionMilliseconds: Int64 = 60 * 24 * 60 * 60 * 1_000

    struct Entry: Equatable {
        let value: JSONValue?
        let time: Int64
    }

    typealias Sections = [String: [String: Entry]]

    /// JSON data that can be carried inside an entry without knowing its section schema.
    indirect enum JSONValue: Equatable, Codable {
        case null
        case boolean(Bool)
        case integer(Int64)
        case unsignedInteger(UInt64)
        case decimal(Decimal)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
                var object: [String: JSONValue] = [:]
                for key in keyed.allKeys {
                    object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
                }
                self = .object(object)
                return
            }

            if var unkeyed = try? decoder.unkeyedContainer() {
                var array: [JSONValue] = []
                while !unkeyed.isAtEnd {
                    array.append(try unkeyed.decode(JSONValue.self))
                }
                self = .array(array)
                return
            }

            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let value = try? single.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? single.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? single.decode(UInt64.self) {
                self = .unsignedInteger(value)
            } else if let value = try? single.decode(Decimal.self) {
                self = .decimal(value)
            } else if let value = try? single.decode(Double.self), value.isFinite {
                self = .decimal(Decimal(value))
            } else if let value = try? single.decode(String.self) {
                self = .string(value)
            } else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .null:
                var single = encoder.singleValueContainer()
                try single.encodeNil()
            case .boolean(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .integer(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .unsignedInteger(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .decimal(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .string(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .array(let values):
                var unkeyed = encoder.unkeyedContainer()
                for value in values { try unkeyed.encode(value) }
            case .object(let values):
                var keyed = encoder.container(keyedBy: AnyCodingKey.self)
                for (key, value) in values {
                    try keyed.encode(value, forKey: AnyCodingKey(stringValue: key)!)
                }
            }
        }
    }

    enum DecodeError: Error, Equatable {
        case newerFormat
    }

    /// Encodes version 1 using sorted keys for stable output.
    static func encode(_ sections: Sections) throws -> String {
        var encodedSections: [String: JSONValue] = [:]
        for (name, entries) in sections where !entries.isEmpty {
            var encodedEntries: [String: JSONValue] = [:]
            for (key, entry) in entries {
                var encodedEntry: [String: JSONValue] = ["t": .integer(entry.time)]
                if let value = entry.value { encodedEntry["v"] = value }
                encodedEntries[key] = .object(encodedEntry)
            }
            encodedSections[name] = .object(encodedEntries)
        }

        let root: JSONValue = .object([
            "v": .integer(Int64(version)),
            "s": .object(encodedSections),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(root)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes sections; blank, malformed, or structurally unreadable documents are empty.
    /// Documents with a valid integer version newer than this implementation are rejected.
    static func decode(_ text: String?) throws -> Sections {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = decoded else { return [:] }

        guard let documentVersion = int64(root["v"]) else { return [:] }
        if documentVersion > Int64(version) { throw DecodeError.newerFormat }
        guard case .object(let rawSections)? = root["s"] else { return [:] }

        var sections: Sections = [:]
        for (name, rawSection) in rawSections {
            guard case .object(let rawEntries) = rawSection else { continue }
            var entries: [String: Entry] = [:]
            for (key, rawEntry) in rawEntries {
                guard case .object(let fields) = rawEntry,
                      let time = int64(fields["t"]) else { continue }
                entries[key] = Entry(value: fields["v"], time: time)
            }
            sections[name] = entries
        }
        return sections
    }

    /// Stamps local changes. New sections start at time zero so their defaults do not
    /// override values already present in the account document.
    static func stamp(base: Sections, current: [String: [String: JSONValue]], now: Int64) -> Sections {
        var result = base
        for (name, values) in current {
            let before = base[name, default: [:]]
            let newTime: Int64 = base[name] == nil ? 0 : now
            var entries: [String: Entry] = [:]

            for (key, value) in values {
                guard let old = before[key] else {
                    entries[key] = Entry(value: value, time: newTime)
                    continue
                }
                entries[key] = old.value == value ? old : Entry(value: value, time: now)
            }

            for (key, old) in before where values[key] == nil {
                entries[key] = old.value == nil ? old : Entry(value: nil, time: now)
            }

            if entries.isEmpty { result.removeValue(forKey: name) }
            else { result[name] = entries }
        }
        return result
    }

    /// Merges by key; the later timestamp wins and the right-hand document wins ties.
    static func merge(_ left: Sections, _ right: Sections) -> Sections {
        var result: Sections = [:]
        for name in Set(left.keys).union(right.keys) {
            let leftEntries = left[name, default: [:]]
            let rightEntries = right[name, default: [:]]
            var entries: [String: Entry] = [:]
            for key in Set(leftEntries.keys).union(rightEntries.keys) {
                guard let lhs = leftEntries[key] else {
                    entries[key] = rightEntries[key]
                    continue
                }
                guard let rhs = rightEntries[key] else {
                    entries[key] = lhs
                    continue
                }
                entries[key] = lhs.time > rhs.time ? lhs : rhs
            }
            result[name] = entries
        }
        return result
    }

    /// Drops tombstones at least 60 days old and removes sections left empty.
    static func prune(_ sections: Sections, now: Int64) -> Sections {
        var result: Sections = [:]
        for (name, entries) in sections {
            let kept = entries.filter { _, entry in
                guard entry.value == nil else { return true }
                return now &- entry.time < tombstoneRetentionMilliseconds
            }
            if !kept.isEmpty { result[name] = kept }
        }
        return result
    }

    static func values(_ sections: Sections, section: String) -> [String: JSONValue] {
        guard let entries = sections[section] else { return [:] }
        return entries.reduce(into: [:]) { result, element in
            if let value = element.value.value { result[element.key] = value }
        }
    }

    static func latestTime(_ sections: Sections) -> Int64 {
        sections.values
            .map { entries in entries.values.map(\.time).max() ?? 0 }
            .max() ?? 0
    }

    /// Uses the local clock, but never before an edit already observed on any input document.
    static func stampTime(clock: Int64, seen: Sections...) -> Int64 {
        let latestSeen = seen.map(latestTime).max() ?? 0
        return max(clock, latestSeen &+ 1)
    }

    private static func int64(_ value: JSONValue?) -> Int64? {
        switch value {
        case .integer(let number): number
        case .unsignedInteger(let number): number <= UInt64(Int64.max) ? Int64(number) : nil
        default: nil
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
