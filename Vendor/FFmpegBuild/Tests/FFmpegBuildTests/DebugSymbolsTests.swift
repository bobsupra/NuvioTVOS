import Testing
import Foundation

/// Proves the shipped xcframeworks carry the debug symbols an App Store archive
/// needs, and that those symbols belong to the binaries next to them.
///
/// Without a matching dSYM in the archive, every frame of a crash inside these
/// libraries stays an address, and App Store Connect says so on upload
/// ("The archive did not include a dSYM for Libavcodec.framework with the UUIDs
/// [...]", FFmpegBuild#4). Xcode copies an xcframework's dSYMs into the archive
/// on its own, so the whole obligation is on this package.
///
/// Two ways that goes wrong, both invisible in a build log:
///
/// * The libraries get rebuilt without `DEBUG_CFLAG`, or FFmpeg's install-time
///   stripping comes back and takes the debug map with it. The dSYM is then
///   missing or empty.
/// * The xcframeworks get rebuilt and the dSYMs do not (or the other way round).
///   Both exist, both look right, and the UUIDs no longer match, which
///   symbolicates nothing while claiming to.
struct DebugSymbolsTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FFmpegBuildTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private static func xcframeworks() throws -> [URL] {
        let sources = repoRoot.appendingPathComponent("Sources")
        return try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcframework" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One `AvailableLibraries` entry of an xcframework's `Info.plist`.
    private struct Slice {
        let identifier: String
        let libraryPath: String
        let binaryPath: String
        let debugSymbolsPath: String?
        let isSimulator: Bool
    }

    private static func slices(of xcframework: URL) throws -> [Slice] {
        let data = try Data(contentsOf: xcframework.appendingPathComponent("Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let libraries = (plist as? [String: Any])?["AvailableLibraries"] as? [[String: Any]] ?? []
        return libraries.map { entry in
            Slice(
                identifier: entry["LibraryIdentifier"] as? String ?? "",
                libraryPath: entry["LibraryPath"] as? String ?? "",
                binaryPath: entry["BinaryPath"] as? String ?? "",
                debugSymbolsPath: entry["DebugSymbolsPath"] as? String,
                isSimulator: (entry["SupportedPlatformVariant"] as? String) == "simulator"
            )
        }
    }

    /// The Mach-O UUIDs in a file, keyed by `cputype:cpusubtype` so a fat binary
    /// compares per architecture rather than as an unordered pile.
    ///
    /// Reading the load commands here rather than shelling out to `dwarfdump`
    /// keeps the test honest about what a symbolicator looks at: LC_UUID is the
    /// only thing that pairs a binary with its dSYM.
    private static func machOUUIDs(at url: URL) throws -> [String: UUID] {
        let data = try Data(contentsOf: url)

        func u32(_ offset: Int, bigEndian: Bool = false) -> UInt32 {
            let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
            let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }          // big-endian read
            return bigEndian ? value : value.byteSwapped
        }

        // Each slice of a fat file, or the whole file when it is thin.
        var images: [Int] = []
        let magic = u32(0, bigEndian: true)
        switch magic {
        case 0xcafe_babe, 0xcafe_babf:                                              // FAT_MAGIC / FAT_MAGIC_64
            let is64 = magic == 0xcafe_babf
            let count = Int(u32(4, bigEndian: true))
            let entrySize = is64 ? 32 : 20
            for i in 0 ..< count {
                let entry = 8 + i * entrySize
                images.append(is64 ? Int(u32(entry + 12, bigEndian: true)) : Int(u32(entry + 8, bigEndian: true)))
            }
        default:
            images = [0]
        }

        var result: [String: UUID] = [:]
        for image in images {
            let cpuType = u32(image + 4)
            let cpuSubtype = u32(image + 8) & 0x00ff_ffff                            // mask the capability bits
            let ncmds = Int(u32(image + 16))
            var cursor = image + 32                                                  // past mach_header_64
            for _ in 0 ..< ncmds {
                let cmd = u32(cursor)
                let size = Int(u32(cursor + 4))
                if cmd == 0x1b {                                                     // LC_UUID
                    let raw = Array(data[data.startIndex + cursor + 8 ..< data.startIndex + cursor + 24])
                    result["\(cpuType):\(cpuSubtype)"] = UUID(uuid: (
                        raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                        raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
                    ))
                    break
                }
                guard size > 0 else { break }
                cursor += size
            }
        }
        return result
    }

    /// Every slice an app can ship has dSYMs, and no simulator slice does.
    ///
    /// The simulator half is a decision, not an omission: those slices reach
    /// neither an App Store archive nor a user's crash report, and their dSYMs
    /// would be another 45 MB of binaries in every consumer's clone. `build.sh`
    /// still writes them to `build/dsyms` for local use.
    @Test func shippableSlicesCarryDebugSymbolsAndSimulatorSlicesDoNot() throws {
        for xcframework in try Self.xcframeworks() {
            let name = xcframework.lastPathComponent
            let found = try Self.slices(of: xcframework)
            #expect(!found.isEmpty, "\(name) declares no libraries")

            for slice in found {
                if slice.isSimulator {
                    #expect(slice.debugSymbolsPath == nil,
                            "\(name) \(slice.identifier): simulator slices ship without dSYMs on purpose")
                    continue
                }
                guard let debugSymbolsPath = slice.debugSymbolsPath else {
                    Issue.record("\(name) \(slice.identifier): no DebugSymbolsPath, crashes here cannot symbolicate")
                    continue
                }
                let dSYM = xcframework
                    .appendingPathComponent(slice.identifier)
                    .appendingPathComponent(debugSymbolsPath)
                    .appendingPathComponent("\(slice.libraryPath).dSYM")
                #expect(FileManager.default.fileExists(atPath: dSYM.path),
                        "\(name) \(slice.identifier): \(dSYM.lastPathComponent) is missing")
            }
        }
    }

    /// The dSYM and the binary next to it describe the same build, architecture
    /// by architecture. A mismatch is worse than a missing dSYM: the archive
    /// looks complete and symbolicates nothing.
    @Test func debugSymbolUUIDsMatchTheShippedBinaries() throws {
        var compared = 0
        var expected = 0
        for xcframework in try Self.xcframeworks() {
            let name = xcframework.lastPathComponent
            for slice in try Self.slices(of: xcframework) where !slice.isSimulator {
                expected += 1
                guard let debugSymbolsPath = slice.debugSymbolsPath else { continue }
                let sliceRoot = xcframework.appendingPathComponent(slice.identifier)
                let binary = sliceRoot.appendingPathComponent(slice.binaryPath)
                let dwarfDir = sliceRoot
                    .appendingPathComponent(debugSymbolsPath)
                    .appendingPathComponent("\(slice.libraryPath).dSYM/Contents/Resources/DWARF")

                guard let dwarf = try? FileManager.default
                    .contentsOfDirectory(at: dwarfDir, includingPropertiesForKeys: nil).first else {
                    Issue.record("\(name) \(slice.identifier): dSYM carries no DWARF binary")
                    continue
                }

                let binaryUUIDs = try Self.machOUUIDs(at: binary)
                let dwarfUUIDs = try Self.machOUUIDs(at: dwarf)

                #expect(!binaryUUIDs.isEmpty, "\(name) \(slice.identifier): binary has no LC_UUID")
                #expect(binaryUUIDs == dwarfUUIDs,
                        "\(name) \(slice.identifier): dSYM is from a different build (binary \(binaryUUIDs), dSYM \(dwarfUUIDs))")
                compared += 1
            }
        }

        // Without this the test passes on a build that ships no dSYMs at all:
        // every slice would be skipped and nothing would be compared.
        #expect(compared == expected,
                "compared \(compared) of \(expected) shippable slices, the rest carry no dSYM")
    }
}
