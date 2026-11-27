import Foundation

/// A value a template field can hold.
enum DebridTemplateValue: Equatable {
    case none
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([String])
    case bytes(Int64)
}

/// The desktop app's result template language, read once into a tree so a
/// list of results can be drawn without reading the template text again.
///
/// A template is text with `{field}` placeholders. A placeholder can change
/// its value (`{stream.size::bytes}`, `{stream.audioTags::join(' | ')}`) or
/// choose between two texts (`{stream.quality::exists["yes"||"no"]}`), and
/// the chosen text is itself a template.
struct DebridStreamTemplate {
    /// Every field the desktop app's templates can name. This app fills the
    /// ones it can read from a result (see `DebridStreamFormatting.values`).
    static let knownFields: Set<String> = [
        "stream.title", "stream.year", "stream.season", "stream.episode", "stream.seasons", "stream.episodes",
        "stream.seasonEpisode", "stream.formattedEpisodes", "stream.formattedSeasons", "stream.resolution",
        "stream.library", "stream.quality", "stream.visualTags", "stream.audioTags", "stream.audioChannels",
        "stream.languages", "stream.languageEmojis", "stream.size", "stream.folderSize", "stream.encode",
        "stream.indexer", "stream.network", "stream.releaseGroup", "stream.duration", "stream.edition",
        "stream.filename", "stream.regexMatched", "stream.rseMatched", "stream.type",
        "service.cached", "service.shortName", "service.name", "addon.name"
    ]

    private static let maximumDepth = 8

    private enum Transform {
        case title, lower, upper, bytes, time
        case join(String)
        case replace(String, String)
    }

    private enum Comparison {
        case greaterOrEqual, lessOrEqual, greater, less
    }

    private enum Check {
        case exists, isTrue, isFalse
        case contains(String)
        case equals(String)
        case compare(Comparison, Double)
    }

    private struct Test {
        let field: String
        let checks: [Check]
    }

    private indirect enum Node {
        case text(String)
        case value(field: String, transforms: [Transform])
        /// True when every test of any one group passes.
        case choice(groups: [[Test]], whenTrue: [Node], whenFalse: [Node])
    }

    private let nodes: [Node]

    // MARK: - Reading a template

    /// Nil when the text is not a template this app can draw: a placeholder
    /// left open, a field or operation it does not know, or a comparison
    /// with something that is not a number.
    init?(_ source: String) {
        // The tvOS keyboard can type curly quotes, which the language does not use.
        let straight = source
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
        guard let nodes = Self.parse(Array(straight), depth: 0) else { return nil }
        self.nodes = nodes
    }

    private static func parse(_ chars: [Character], depth: Int) -> [Node]? {
        guard depth <= maximumDepth else { return nil }
        var nodes: [Node] = []
        var literal = ""
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else {
                literal.append(chars[index])
                index += 1
                continue
            }
            guard let end = placeholderEnd(chars, from: index + 1),
                  let node = parseExpression(Array(chars[(index + 1)..<end]), depth: depth) else { return nil }
            if !literal.isEmpty {
                nodes.append(.text(literal))
                literal = ""
            }
            nodes.append(node)
            index = end + 1
        }
        if !literal.isEmpty { nodes.append(.text(literal)) }
        return nodes
    }

    /// The closing brace of a placeholder. Braces inside quotes belong to a
    /// nested template.
    private static func placeholderEnd(_ chars: [Character], from start: Int) -> Int? {
        var quote: Character?
        var index = start
        while index < chars.count {
            let char = chars[index]
            if let open = quote {
                if char == open, chars[index - 1] != "\\" { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "}" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func parseExpression(_ chars: [Character], depth: Int) -> Node? {
        if let bracket = topLevelIndex(of: "[", in: chars) {
            guard chars.last == "]" else { return nil }
            let condition = Array(chars[..<bracket])
            let branches = splitBranches(Array(chars[(bracket + 1)..<(chars.count - 1)]))
            guard let groups = parseCondition(condition),
                  let whenTrue = parse(Array(branches.0), depth: depth + 1),
                  let whenFalse = parse(Array(branches.1), depth: depth + 1) else { return nil }
            return .choice(groups: groups, whenTrue: whenTrue, whenFalse: whenFalse)
        }
        let tokens = splitOperations(chars)
        guard let field = tokens.first, knownFields.contains(field) else { return nil }
        var transforms: [Transform] = []
        for token in tokens.dropFirst() {
            guard let transform = parseTransform(token) else { return nil }
            transforms.append(transform)
        }
        return .value(field: field, transforms: transforms)
    }

    /// Tests joined by `and` form a group, and `or` starts the next group.
    private static func parseCondition(_ chars: [Character]) -> [[Test]]? {
        let tokens = splitOperations(chars)
        guard !tokens.isEmpty else { return nil }
        var groups: [[Test]] = []
        var current: [Test] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "or" {
                groups.append(current)
                current = []
                index += 1
            } else if token == "and" {
                index += 1
            } else {
                guard knownFields.contains(token) else { return nil }
                index += 1
                var checks: [Check] = []
                while index < tokens.count, tokens[index] != "and", tokens[index] != "or", !isFieldPath(tokens[index]) {
                    guard let check = parseCheck(tokens[index]) else { return nil }
                    checks.append(check)
                    index += 1
                }
                current.append(Test(field: token, checks: checks))
            }
        }
        groups.append(current)
        return groups
    }

    private static func isFieldPath(_ token: String) -> Bool {
        token.hasPrefix("stream.") || token.hasPrefix("service.") || token.hasPrefix("addon.")
    }

    private static func parseCheck(_ token: String) -> Check? {
        /// The value after the operator. It may be written in quotes.
        func rest(_ count: Int) -> String {
            unquoted(String(token.dropFirst(count)))
        }
        func compare(_ comparison: Comparison, _ count: Int) -> Check? {
            Double(rest(count)).map { .compare(comparison, $0) }
        }
        if token == "exists" { return .exists }
        if token == "istrue" { return .isTrue }
        if token == "isfalse" { return .isFalse }
        if token.hasPrefix("~=") { return .contains(rest(2)) }
        if token.hasPrefix("~") { return .contains(rest(1)) }
        if token.hasPrefix("=") { return .equals(rest(1)) }
        if token.hasPrefix(">=") { return compare(.greaterOrEqual, 2) }
        if token.hasPrefix("<=") { return compare(.lessOrEqual, 2) }
        if token.hasPrefix(">") { return compare(.greater, 1) }
        if token.hasPrefix("<") { return compare(.less, 1) }
        return nil
    }

    private static func parseTransform(_ token: String) -> Transform? {
        switch token {
        case "title": return .title
        case "lower": return .lower
        case "upper": return .upper
        case "bytes": return .bytes
        case "time": return .time
        default: break
        }
        if token.hasPrefix("join(") {
            guard let arguments = parseArguments(token) else { return nil }
            return .join(arguments.first ?? ", ")
        }
        if token.hasPrefix("replace(") {
            guard let arguments = parseArguments(token), arguments.count >= 2 else { return nil }
            return .replace(arguments[0], arguments[1])
        }
        return nil
    }

    /// Walks `chars` outside quotes, telling `visit` each index and the
    /// depth of round brackets there. `visit` returns false to stop.
    private static func scanOutsideQuotes(_ chars: [Character], _ visit: (Int, Int) -> Bool) {
        var quote: Character?
        var depth = 0
        for (index, char) in chars.enumerated() {
            if let open = quote {
                if char == open, index > 0, chars[index - 1] != "\\" { quote = nil }
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                continue
            }
            if char == "(" {
                depth += 1
            } else if char == ")" {
                depth = max(depth - 1, 0)
            }
            if !visit(index, depth) { return }
        }
    }

    private static func topLevelIndex(of target: Character, in chars: [Character]) -> Int? {
        var found: Int?
        scanOutsideQuotes(chars) { index, depth in
            guard chars[index] == target, depth == 0 else { return true }
            found = index
            return false
        }
        return found
    }

    /// The parts of a placeholder between `::`.
    private static func splitOperations(_ chars: [Character]) -> [String] {
        var cuts: [Int] = []
        var skip = -1
        scanOutsideQuotes(chars) { index, depth in
            if index > skip, depth == 0, chars[index] == ":", index + 1 < chars.count, chars[index + 1] == ":" {
                cuts.append(index)
                skip = index + 1
            }
            return true
        }
        var tokens: [String] = []
        var start = 0
        for cut in cuts {
            tokens.append(String(chars[start..<cut]))
            start = cut + 2
        }
        tokens.append(String(chars[start...]))
        return tokens
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The two texts of a choice, either side of `||`.
    private static func splitBranches(_ chars: [Character]) -> (String, String) {
        var separator: Int?
        scanOutsideQuotes(chars) { index, _ in
            guard chars[index] == "|", index + 1 < chars.count, chars[index + 1] == "|" else { return true }
            separator = index
            return false
        }
        guard let separator else { return (unquoted(String(chars)), "") }
        return (unquoted(String(chars[..<separator])), unquoted(String(chars[(separator + 2)...])))
    }

    private static func parseArguments(_ token: String) -> [String]? {
        let chars = Array(token)
        guard let open = chars.firstIndex(of: "("), let close = chars.lastIndex(of: ")"), close > open else { return nil }
        let body = Array(chars[(open + 1)..<close])
        var arguments: [String] = []
        var quote: Character?
        var start = 0
        for (index, char) in body.enumerated() {
            if let opened = quote {
                if char == opened, index > 0, body[index - 1] != "\\" { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "," {
                arguments.append(unquoted(String(body[start..<index])))
                start = index + 1
            }
        }
        arguments.append(unquoted(String(body[start...])))
        return arguments
    }

    private static func unquoted(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - Drawing a result

    func render(_ values: [String: DebridTemplateValue]) -> String {
        var output = ""
        Self.render(nodes, values, into: &output)
        return output
    }

    private static func render(_ nodes: [Node], _ values: [String: DebridTemplateValue], into output: inout String) {
        for node in nodes {
            switch node {
            case .text(let text):
                output += text
            case .value(let field, let transforms):
                var value = values[field] ?? .none
                for transform in transforms {
                    value = .text(apply(transform, to: value))
                }
                output += text(of: value)
            case .choice(let groups, let whenTrue, let whenFalse):
                let chosen = groups.contains { group in
                    !group.isEmpty && group.allSatisfy { passes($0, values[$0.field] ?? .none) }
                }
                render(chosen ? whenTrue : whenFalse, values, into: &output)
            }
        }
    }

    private static func passes(_ test: Test, _ value: DebridTemplateValue) -> Bool {
        guard !test.checks.isEmpty else { return isTruthy(value) }
        var result = false
        var hasResult = false
        for check in test.checks {
            switch check {
            case .exists:
                result = exists(value)
            case .isTrue:
                // After another check, `istrue` keeps that check's answer and `isfalse` turns it round.
                result = hasResult ? result : boolean(value) == true
            case .isFalse:
                result = hasResult ? !result : boolean(value) == false
            case .contains(let target):
                result = texts(of: value).contains { target.isEmpty || $0.range(of: target, options: .caseInsensitive) != nil }
            case .equals(let target):
                result = texts(of: value).contains {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(target) == .orderedSame
                }
            case .compare(let comparison, let target):
                if let number = number(value) {
                    switch comparison {
                    case .greaterOrEqual: result = number >= target
                    case .lessOrEqual: result = number <= target
                    case .greater: result = number > target
                    case .less: result = number < target
                    }
                } else {
                    result = false
                }
            }
            hasResult = true
        }
        return result
    }

    private static func apply(_ transform: Transform, to value: DebridTemplateValue) -> String {
        switch transform {
        case .title:
            return text(of: value)
                .split(whereSeparator: { $0.isWhitespace })
                .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
                .joined(separator: " ")
        case .lower:
            return text(of: value).lowercased()
        case .upper:
            return text(of: value).uppercased()
        case .bytes:
            return number(value).map(formatBytes) ?? ""
        case .time:
            return number(value).map(formatTime) ?? ""
        case .join(let separator):
            if case .list(let items) = value {
                return items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: separator)
            }
            return text(of: value)
        case .replace(let target, let replacement):
            let source = text(of: value)
            return target.isEmpty ? source : source.replacingOccurrences(of: target, with: replacement)
        }
    }

    /// The value as one text for each part, for `=` and `~`.
    private static func texts(of value: DebridTemplateValue) -> [String] {
        if case .list(let items) = value { return items }
        return [text(of: value)]
    }

    private static func text(of value: DebridTemplateValue) -> String {
        switch value {
        case .none: return ""
        case .text(let text): return text
        case .number(let number):
            return number.truncatingRemainder(dividingBy: 1) == 0 && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .list(let items):
            return items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: ", ")
        case .bytes(let bytes): return formatBytes(Double(bytes))
        }
    }

    private static func exists(_ value: DebridTemplateValue) -> Bool {
        switch value {
        case .none: return false
        case .text(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .list(let items): return !items.isEmpty
        case .number, .bool, .bytes: return true
        }
    }

    private static func isTruthy(_ value: DebridTemplateValue) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .bytes(let bytes): return bytes != 0
        case .number(let number): return number != 0
        case .none, .text, .list: return exists(value)
        }
    }

    private static func boolean(_ value: DebridTemplateValue) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .text("true"): return true
        case .text("false"): return false
        default: return nil
        }
    }

    private static func number(_ value: DebridTemplateValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .bytes(let bytes): return Double(bytes)
        case .text(let text): return Double(text)
        case .none, .bool, .list: return nil
        }
    }

    /// 1536 gives "1.5 KB", 5 GB gives "5 GB" and 12.4 GB gives "12 GB", as the desktop app writes sizes.
    static func formatBytes(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 9e18 else { return "" }
        let bytes = abs(value)
        guard bytes >= 1024 else { return "\(Int64(value)) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var current = bytes
        var unit = -1
        while current >= 1024, unit < units.count - 1 {
            current /= 1024
            unit += 1
        }
        let signed = value < 0 ? -current : current
        if signed >= 10 || signed.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int64(signed)) \(units[unit])"
        }
        let tenths = Int64((signed * 10).rounded())
        // 9.96 rounds up to a whole 10.
        if abs(tenths) >= 100 { return "\(tenths / 10) \(units[unit])" }
        return "\(tenths / 10).\(abs(tenths % 10)) \(units[unit])"
    }

    static func formatTime(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e12 else { return "" }
        let seconds = Int64(value)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds % 60)s"
    }
}

/// One choice the Name template and Description template rows offer.
struct DebridTemplatePreset: Equatable {
    let key: String
    let label: String
    let template: String
}

/// Settings → Connected Services → Formatting: how the name and description
/// of a debrid result are written in the source lists. Both settings are
/// empty by default, which leaves the result as `DebridStreamPresentation`
/// named it and the add-on described it. A template is only applied where a
/// result is drawn, so ranking, auto-select and resume matching always read
/// the result's own text.
struct DebridStreamFormatting {
    /// The stored value for the app's own formatting.
    static let defaultFormat = ""

    /// The desktop app's default name: "2160p TB Instant".
    static let desktopNameTemplate =
        #"{stream.resolution::exists["{stream.resolution} "||""]}{service.shortName::exists["{service.shortName}"||"Cloud"]} Instant"#

    /// The desktop app's earlier name: "4K TB Ready".
    static let legacyNameTemplate =
        #"{stream.resolution::=2160p["4K "||""]}{stream.resolution::=1440p["QHD "||""]}{stream.resolution::=1080p["FHD "||""]}{stream.resolution::=720p["HD "||""]}{service.shortName::exists["{service.shortName} "||"Debrid "]}{service.cached::istrue["Ready"||"Not Ready"]}"#

    static let qualityNameTemplate =
        #"{stream.resolution::exists["{stream.resolution} "||""]}{stream.quality::exists["{stream.quality} "||""]}{service.shortName}"#

    static let encodeNameTemplate =
        #"{stream.resolution::exists["{stream.resolution} "||""]}{stream.quality::exists["{stream.quality} "||""]}{stream.encode::exists["{stream.encode} "||""]}{service.shortName}"#

    /// The desktop app's earlier description, one line per group of facts.
    static let legacyDescriptionTemplate =
        "{stream.title::exists[\"{stream.title::title} \"||\"\"]}{stream.year::exists[\"({stream.year})\"||\"\"]}\n"
        + "{stream.quality::exists[\"{stream.quality} \"||\"\"]}{stream.visualTags::exists[\"{stream.visualTags::join(' | ')} \"||\"\"]}{stream.encode::exists[\"{stream.encode} \"||\"\"]}\n"
        + "{stream.audioTags::exists[\"{stream.audioTags::join(' | ')}\"||\"\"]}{stream.audioTags::exists::and::stream.audioChannels::exists[\" | \"||\"\"]}{stream.audioChannels::exists[\"{stream.audioChannels::join(' | ')}\"||\"\"]}\n"
        + "{stream.size::>0[\"{stream.size::bytes} \"||\"\"]}{stream.releaseGroup::exists[\"{stream.releaseGroup} \"||\"\"]}{stream.indexer::exists[\"{stream.indexer}\"||\"\"]}\n"
        + "{service.cached::istrue[\"Ready\"||\"Not Ready\"]}{service.shortName::exists[\" ({service.shortName})\"||\"\"]}{stream.filename::exists[\"\n{stream.filename}\"||\"\"]}"

    static let compactDescriptionTemplate =
        #"{stream.quality::exists["{stream.quality} "||""]}{stream.encode::exists["{stream.encode} "||""]}{stream.audioTags::exists["{stream.audioTags::join(' ')} "||""]}{stream.size::>0["{stream.size::bytes} "||""]}{stream.releaseGroup::exists["{stream.releaseGroup}"||""]}"#

    static let filenameDescriptionTemplate = "{stream.filename}"

    static let namePresets = [
        DebridTemplatePreset(key: "tvos_debrid_template_name_desktop", label: "2160p TB Instant", template: desktopNameTemplate),
        DebridTemplatePreset(key: "tvos_debrid_template_name_legacy", label: "4K TB Ready", template: legacyNameTemplate),
        DebridTemplatePreset(key: "tvos_debrid_template_name_quality", label: "2160p WEB-DL TB", template: qualityNameTemplate),
        DebridTemplatePreset(key: "tvos_debrid_template_name_encode", label: "2160p WEB-DL HEVC TB", template: encodeNameTemplate)
    ]

    static let descriptionPresets = [
        DebridTemplatePreset(key: "tvos_debrid_template_description_details", label: "Quality, audio, size and file", template: legacyDescriptionTemplate),
        DebridTemplatePreset(key: "tvos_debrid_template_description_compact", label: "One line of facts", template: compactDescriptionTemplate),
        DebridTemplatePreset(key: "tvos_debrid_template_description_filename", label: "File name", template: filenameDescriptionTemplate)
    ]

    /// False for text that is set but cannot be read as a template.
    static func isUsable(_ template: String) -> Bool {
        template.isEmpty || compiled(template) != nil
    }

    let nameTemplate: String
    let descriptionTemplate: String
    private let settings: UserDefaults

    init(settings: UserDefaults = ProfileSettings.current) {
        self.settings = settings
        nameTemplate = settings.string(forKey: SettingsKey.debridNameTemplate) ?? Self.defaultFormat
        descriptionTemplate = settings.string(forKey: SettingsKey.debridDescriptionTemplate) ?? Self.defaultFormat
    }

    /// True with the defaults, when no result is rewritten.
    var isDefault: Bool {
        nameTemplate.isEmpty && descriptionTemplate.isEmpty
    }

    /// What to draw for a result in place of its own text. A nil part keeps
    /// the result's own name or description.
    struct Display: Equatable {
        let name: String?
        let description: String?
    }

    private final class DisplayBox: @unchecked Sendable {
        let display: Display?
        init(_ display: Display?) { self.display = display }
    }

    private final class TemplateBox: @unchecked Sendable {
        let template: DebridStreamTemplate?
        init(_ template: DebridStreamTemplate?) { self.template = template }
    }

    private static let displayCache: NSCache<NSString, DisplayBox> = {
        let cache = NSCache<NSString, DisplayBox>()
        cache.countLimit = 1000
        return cache
    }()

    private static let templateCache: NSCache<NSString, TemplateBox> = {
        let cache = NSCache<NSString, TemplateBox>()
        cache.countLimit = 16
        return cache
    }()

    /// The template read once. Nil for text that is not a template.
    private static func compiled(_ source: String) -> DebridStreamTemplate? {
        let key = source as NSString
        if let cached = templateCache.object(forKey: key) { return cached.template }
        let template = DebridStreamTemplate(source)
        templateCache.setObject(TemplateBox(template), forKey: key)
        return template
    }

    /// Nil unless a template is set and the stream is a result the debrid
    /// service confirmed and this app named. Called as a source row is
    /// drawn, and kept per result so a redraw costs one lookup.
    func display(for stream: NuvioStream) -> Display? {
        guard !isDefault, stream.isCached == true else { return nil }
        let resolver = DebridResolver(store: settings)
        guard resolver.isEnabled else { return nil }
        let provider = resolver.selectedKind
        let key = [
            stream.id, stream.name ?? "", stream.description ?? "", stream.filename ?? "",
            String(stream.videoSize ?? 0), provider.rawValue, nameTemplate, descriptionTemplate
        ].joined(separator: "\u{1}") as NSString
        if let cached = Self.displayCache.object(forKey: key) { return cached.display }
        var display: Display?
        if DebridStreamPresentation.isFormattedResult(stream, provider: provider) {
            let values = Self.values(
                facts: DebridStreamFacts.facts(for: stream),
                filename: stream.filename,
                addonName: stream.addonName,
                provider: provider
            )
            let rendered = Self.render(nameTemplate: nameTemplate, descriptionTemplate: descriptionTemplate, values: values)
            if rendered.name != nil || rendered.description != nil { display = rendered }
        }
        Self.displayCache.setObject(DisplayBox(display), forKey: key)
        return display
    }

    /// The name on one line and the description without blank lines. A part
    /// is nil when its template is empty, cannot be read or draws nothing,
    /// so the result keeps its own text there.
    static func render(
        nameTemplate: String,
        descriptionTemplate: String,
        values: [String: DebridTemplateValue]
    ) -> Display {
        var name: String?
        if !nameTemplate.isEmpty, let template = compiled(nameTemplate) {
            let line = template.render(values)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            name = line.isEmpty ? nil : line
        }
        var description: String?
        if !descriptionTemplate.isEmpty, let template = compiled(descriptionTemplate) {
            let lines = template.render(values)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            description = lines.isEmpty ? nil : lines
        }
        return Display(name: name, description: description)
    }

    /// The fields this app can fill. The title, year, season, episode,
    /// indexer, network, duration and edition fields of the desktop app are
    /// left empty: an add-on result here does not carry them.
    static func values(
        facts: DebridStreamFacts,
        filename: String?,
        addonName: String?,
        provider: DebridProviderKind
    ) -> [String: DebridTemplateValue] {
        func label(_ facet: DebridRuleFacet, _ id: String) -> DebridTemplateValue {
            guard id != DebridRuleFacet.unknown, let found = facet.label(for: id) else { return .none }
            return .text(found)
        }
        func labels(_ facet: DebridRuleFacet, _ ids: [String]) -> DebridTemplateValue {
            .list(ids.filter { $0 != DebridRuleFacet.unknown }.compactMap { facet.label(for: $0) })
        }
        func text(_ value: String?) -> DebridTemplateValue {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
            return .text(value)
        }
        let languageCodes = facts.languages.map { $0.lowercased() }
        return [
            "stream.resolution": label(.resolutions, facts.resolution),
            "stream.library": .bool(false),
            "stream.quality": label(.qualities, facts.quality),
            "stream.visualTags": labels(.visualTags, facts.visualTags),
            "stream.audioTags": labels(.audioTags, facts.audioTags),
            "stream.audioChannels": labels(.audioChannels, facts.audioChannels),
            "stream.languages": .list(languageCodes),
            "stream.languageEmojis": .list(languageCodes.map(regionCode)),
            "stream.size": facts.sizeBytes > 0 ? .bytes(facts.sizeBytes) : .none,
            "stream.encode": label(.encodes, facts.encode),
            "stream.releaseGroup": text(facts.releaseGroup),
            "stream.filename": text(filename),
            "stream.type": .text("Debrid"),
            "service.cached": .bool(true),
            "service.shortName": text(provider.shortName),
            "service.name": provider == .none ? .none : .text(provider.rawValue),
            "addon.name": text(addonName)
        ]
    }

    /// The region the desktop app writes for a language code.
    private static func regionCode(_ language: String) -> String {
        switch language {
        case "en": return "GB"
        case "hi": return "IN"
        case "ja": return "JP"
        case "ko": return "KR"
        case "fr": return "FR"
        case "es": return "ES"
        case "de": return "DE"
        case "it": return "IT"
        case "multi": return "Multi"
        default: return language
        }
    }
}
