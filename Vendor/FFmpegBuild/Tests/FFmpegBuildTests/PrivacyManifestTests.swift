import Testing
import Foundation

/// FFmpegBuild#10: a framework that calls one of Apple's required-reason APIs
/// carries a `PrivacyInfo.xcprivacy` declaring it, so an app embedding these
/// frameworks does not have to declare FFmpeg's calls on its behalf (and App
/// Store Connect does not flag the upload with ITMS-91053).
///
/// `build.sh` derives the manifest from what the binary imports; this checks the
/// committed frameworks against their own symbol tables, so a rebuild that loses
/// the step, or a manifest left behind on a slice that no longer needs it, fails here.
struct PrivacyManifestTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FFmpegBuildTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private static let fileTimestampSymbols: Set<String> = [
        "stat", "fstat", "lstat", "fstatat",
        "getattrlist", "fgetattrlist", "getattrlistat", "getattrlistbulk",
    ]

    private static func importedSymbols(of binary: URL) throws -> Set<String> {
        let nm = Process()
        nm.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        nm.arguments = ["nm", "-u", binary.path]
        let pipe = Pipe()
        nm.standardOutput = pipe
        nm.standardError = FileHandle.nullDevice
        try nm.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        nm.waitUntilExit()
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        return Set(lines.map { line in
            var symbol = line.trimmingCharacters(in: .whitespaces)
            if symbol.hasPrefix("_") { symbol.removeFirst() }
            if symbol.hasSuffix("$INODE64") { symbol.removeLast("$INODE64".count) }
            return symbol
        })
    }

    private static func accessedAPICategories(in manifest: URL) throws -> [String: [String]] {
        let data = try Data(contentsOf: manifest)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let entries = plist?["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard let type = entry["NSPrivacyAccessedAPIType"] as? String else { return nil }
            return (type, entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        })
    }

    @Test func everySliceThatStatsAFileDeclaresTheFileTimestampReason() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let xcframeworks = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcframework" }
        #expect(!xcframeworks.isEmpty)

        var declaring = Set<String>()
        for xcframework in xcframeworks {
            let name = xcframework.deletingPathExtension().lastPathComponent
            let slices = try FileManager.default.contentsOfDirectory(at: xcframework, includingPropertiesForKeys: nil)
                .filter { $0.hasDirectoryPath && $0.lastPathComponent != "_CodeSignature" }
            for slice in slices {
                let framework = slice.appendingPathComponent("\(name).framework")
                let isDeep = slice.lastPathComponent.hasPrefix("macos")
                let binary = isDeep
                    ? framework.appendingPathComponent("Versions/A/\(name)")
                    : framework.appendingPathComponent(name)
                let manifest = isDeep
                    ? framework.appendingPathComponent("Versions/A/Resources/PrivacyInfo.xcprivacy")
                    : framework.appendingPathComponent("PrivacyInfo.xcprivacy")
                let stats = !Self.fileTimestampSymbols.isDisjoint(with: try Self.importedSymbols(of: binary))
                let label = "\(name) \(slice.lastPathComponent)"

                guard stats else {
                    #expect(!FileManager.default.fileExists(atPath: manifest.path), "\(label) imports no stat call but ships a manifest")
                    continue
                }
                #expect(FileManager.default.fileExists(atPath: manifest.path), "\(label) imports a stat call and ships no manifest")
                guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
                let reasons = try Self.accessedAPICategories(in: manifest)["NSPrivacyAccessedAPICategoryFileTimestamp"]
                #expect(reasons?.contains("C617.1") == true, "\(label) does not declare C617.1")
                declaring.insert(name)
            }
        }
        // The three the issue measured; a change here is worth noticing either way.
        #expect(declaring == ["AetherLibavformat", "AetherLibavutil", "AetherLibzvbi"])
    }
}
