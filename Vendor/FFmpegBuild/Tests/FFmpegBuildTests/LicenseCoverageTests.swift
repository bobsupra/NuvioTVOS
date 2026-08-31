import Testing
import Foundation

/// Guards the folder adopters are told to copy. The README points App Store
/// adopters at `LICENSES/` as the set to reproduce, so a component whose text
/// is not a file in that folder ships as an unmet obligation rather than a
/// documentation gap.
///
/// The case that motivated this: the table named `ure.c`'s MIT terms but put
/// the text nowhere, naming the source file instead. Adopters copy the folder,
/// not a zvbi checkout, so that notice never travelled (AetherEngine#398).
struct LicenseCoverageTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FFmpegBuildTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private static let licensesDir = repoRoot.appendingPathComponent("LICENSES")

    /// One parsed row of the component table in `LICENSES/README.md`.
    private struct Row {
        let component: String
        let frameworks: [String]
        let license: String
        /// Files the Text column links to, relative to `LICENSES/`.
        let textFiles: [String]
        /// Anything in the Text column that is not a link.
        let textProse: String
    }

    private static func rows() throws -> [Row] {
        let readme = try String(contentsOf: licensesDir.appendingPathComponent("README.md"), encoding: .utf8)
        return readme.split(separator: "\n").compactMap { line -> Row? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .dropFirst().dropLast()
            guard cells.count == 4 else { return nil }
            guard cells.first != "Component", !cells.first!.hasPrefix("---") else { return nil }
            let text = splitLinks(cells[cells.startIndex + 3])
            return Row(
                component: cells[cells.startIndex],
                frameworks: backticked(cells[cells.startIndex + 1]),
                license: cells[cells.startIndex + 2],
                textFiles: text.targets,
                textProse: text.leftover.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            )
        }
    }

    /// Splits a markdown cell into its `[label](target)` targets and whatever text is left over.
    private static func splitLinks(_ cell: String) -> (targets: [String], leftover: String) {
        var targets: [String] = []
        var leftover = ""
        var rest = Substring(cell)
        while let open = rest.firstIndex(of: "[") {
            leftover += rest[rest.startIndex ..< open]
            let afterLabel = rest[open...].firstIndex(of: "]")
            guard let close = afterLabel,
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(",
                  let paren = rest[close...].firstIndex(of: ")") else {
                leftover += rest[open...]
                return (targets, leftover)
            }
            targets.append(String(rest[rest.index(close, offsetBy: 2) ..< paren]))
            rest = rest[rest.index(after: paren)...]
        }
        leftover += rest
        return (targets, leftover)
    }

    private static func backticked(_ cell: String) -> [String] {
        cell.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) }
    }

    @Test("every shipped xcframework is covered by a row")
    func everyFrameworkHasARow() throws {
        let shipped = try FileManager.default
            .contentsOfDirectory(atPath: Self.repoRoot.appendingPathComponent("Sources").path)
            .filter { $0.hasSuffix(".xcframework") }
            .map { String($0.dropLast(".xcframework".count)) }
        let covered = Set(try Self.rows().flatMap(\.frameworks))
        #expect(!shipped.isEmpty)
        for framework in shipped {
            #expect(covered.contains(framework), "\(framework).xcframework ships with no row in LICENSES/README.md")
        }
    }

    @Test("every row's text is a file in LICENSES, not a pointer somewhere else")
    func everyRowShipsItsText() throws {
        for row in try Self.rows() {
            #expect(!row.textFiles.isEmpty, "\(row.component) names \(row.license) but links no text")
            #expect(
                row.textProse.isEmpty,
                "\(row.component)'s Text column carries prose (\"\(row.textProse)\"); adopters copy files, so the text has to be one"
            )
            for file in row.textFiles {
                let path = Self.licensesDir.appendingPathComponent(file).path
                #expect(FileManager.default.fileExists(atPath: path), "\(row.component) links \(file), which is not in LICENSES/")
            }
        }
    }

    @Test("no license text sits in the folder unreferenced")
    func noOrphanedTexts() throws {
        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: Self.licensesDir.path)
            .filter { $0.hasSuffix(".txt") }
        let linked = Set(try Self.rows().flatMap(\.textFiles))
        #expect(!onDisk.isEmpty)
        for file in onDisk {
            #expect(linked.contains(file), "LICENSES/\(file) is not referenced by any row, so nothing says which component needs it")
        }
    }
}
