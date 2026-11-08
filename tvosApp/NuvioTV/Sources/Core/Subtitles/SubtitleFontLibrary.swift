import CoreText
import Foundation
import SwiftUI
import UIKit

// MARK: - Custom subtitle fonts (Settings → Subtitles → Custom Fonts)

/// One font file the viewer added for subtitles. A TTC holds several faces, so the names are lists.
struct SubtitleFont: Codable, Identifiable, Hashable, Sendable {
    /// The file's name in the fonts folder.
    let id: String
    let families: [String]
    let fullNames: [String]
    let postScriptNames: [String]
    let bytes: Int
    /// Where it was downloaded from; nil for a file sent from another device.
    let link: String?
    let addedAt: Date

    var family: String { families.first ?? fullNames.first ?? id }
    var displayName: String { fullNames.first ?? family }
}

/// A face read from a font file.
struct SubtitleFontFace: Equatable, Sendable {
    let postScriptName: String
    let family: String
    let fullName: String
}

enum SubtitleFontLimits {
    /// One font file.
    static let fontBytes = 30_000_000
    /// One upload or download (a ZIP of fonts).
    static let downloadBytes = 100_000_000
    static let fontsPerArchive = 50
}

enum SubtitleFontError: LocalizedError, Equatable {
    case notAFont
    case webFont
    case webPage
    case tooLarge(Int)
    case noFontsInArchive
    case unsupportedArchive
    case badLink
    case download(Int)
    case googleFontsFamily(String)
    case couldNotSave(String)

    var errorDescription: String? {
        switch self {
        case .notAFont:
            return "This isn't a font file. Use TTF, OTF or TTC, or a ZIP with fonts in it."
        case .webFont:
            return "WOFF web fonts can't be used for subtitles. Use the TTF or OTF version."
        case .webPage:
            return "The link opens a web page, not a file. Use a direct download link."
        case let .tooLarge(limit):
            return "The file is larger than \(limit / 1_000_000) MB."
        case .noFontsInArchive:
            return "The ZIP has no TTF, OTF or TTC fonts in it."
        case .unsupportedArchive:
            return "This ZIP can't be opened."
        case .badLink:
            return "That isn't a web link."
        case let .download(status):
            return "The download failed (HTTP \(status))."
        case let .googleFontsFamily(family):
            return "Google Fonts didn't offer a family called \(family)."
        case let .couldNotSave(reason):
            return "The font couldn't be saved on this Apple TV (\(reason))."
        }
    }

    /// The message for any error from adding a font.
    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// What a downloaded or uploaded file is, from its first bytes.
enum SubtitleFontPayload: Equatable {
    case font(fileExtension: String)
    case zip
    case webFont
    case webPage
    case unknown

    static func kind(of data: Data) -> SubtitleFontPayload {
        let head = [UInt8](data.prefix(4))
        if head.count == 4 {
            switch head {
            case [0x00, 0x01, 0x00, 0x00], [0x74, 0x72, 0x75, 0x65]: return .font(fileExtension: "ttf") // TrueType, "true"
            case [0x4F, 0x54, 0x54, 0x4F]: return .font(fileExtension: "otf") // "OTTO"
            case [0x74, 0x74, 0x63, 0x66]: return .font(fileExtension: "ttc") // "ttcf"
            case [0x77, 0x4F, 0x46, 0x46], [0x77, 0x4F, 0x46, 0x32]: return .webFont // "wOFF", "wOF2"
            case [0x50, 0x4B, 0x03, 0x04]: return .zip // "PK\3\4"
            default: break
            }
        }
        let skipped: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF]
        if data.prefix(512).first(where: { !skipped.contains($0) }) == 0x3C { return .webPage } // "<"
        return .unknown
    }
}

/// Reading font files, and finding an installed family's regular face.
enum SubtitleFontFaces {
    static func faces(in data: Data) -> [SubtitleFontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.compactMap { descriptor in
            guard let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !postScriptName.isEmpty else { return nil }
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            let fullName = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String
            return SubtitleFontFace(
                postScriptName: postScriptName,
                family: family ?? postScriptName,
                fullName: fullName ?? postScriptName
            )
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var regularNames: [String: String] = [:]
    nonisolated(unsafe) private static var absentFamilies: Set<String> = []

    /// The PostScript name of an installed family's upright regular face ("Roboto" →
    /// "Roboto-Regular"): a family name alone isn't a font name. Nil when no such family is installed.
    static func regularFaceName(family: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = regularNames[family] { return cached }
        if absentFamilies.contains(family) { return nil }
        let names = UIFont.fontNames(forFamilyName: family)
        let upright = names.filter { name in
            guard let traits = UIFont(name: name, size: 12)?.fontDescriptor.symbolicTraits else { return false }
            return !traits.contains(.traitBold) && !traits.contains(.traitItalic)
        }
        guard let pick = upright.first(where: { $0.range(of: "Regular", options: .caseInsensitive) != nil })
                ?? upright.sorted().first
                ?? names.sorted().first else {
            absentFamilies.insert(family)
            return nil
        }
        regularNames[family] = pick
        return pick
    }

    static func font(family: String, size: CGFloat) -> UIFont? {
        regularFaceName(family: family).flatMap { UIFont(name: $0, size: size) }
    }

    /// After fonts are added or removed.
    static func invalidate() {
        lock.lock()
        regularNames.removeAll()
        absentFamilies.removeAll()
        lock.unlock()
    }
}

/// The fonts the viewer added, kept in Caches/SubtitleFonts with a list beside them (tvOS lets an
/// app write only to its caches), and registered for this app at launch so text subtitles, MPV and
/// libass all find them by name.
@MainActor
final class SubtitleFontLibrary: ObservableObject {
    static let shared = SubtitleFontLibrary()

    @Published private(set) var fonts: [SubtitleFont] = []
    /// Listed fonts whose file is gone (tvOS clears app files when the Apple TV runs out of space).
    @Published private(set) var missingIDs: Set<String> = []

    private var loading: Task<Void, Never>?

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SubtitleFonts", isDirectory: true)
    }

    nonisolated private static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    /// The families for the Font choice: present fonts only, in name order.
    var familyNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for font in fonts where !missingIDs.contains(font.id) {
            for family in font.families where seen.insert(family).inserted {
                names.append(family)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var totalBytes: Int {
        fonts.filter { !missingIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    func isMissing(_ font: SubtitleFont) -> Bool {
        missingIDs.contains(font.id)
    }

    /// At launch: reads the list and registers the files, then downloads again what tvOS
    /// removed when it came from a link.
    nonisolated static func prepareAtLaunch() {
        Task { @MainActor in
            await shared.load()
        }
    }

    func load() async {
        if let loading {
            await loading.value
            return
        }
        let task = Task { @MainActor in
            let (stored, present) = await Task.detached(priority: .utility) { () -> ([SubtitleFont], Set<String>) in
                let stored = SubtitleFontLibrary.readIndex()
                var present = Set<String>()
                for font in stored {
                    let url = SubtitleFontLibrary.directory.appendingPathComponent(font.id)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    SubtitleFontLibrary.register(url)
                    present.insert(font.id)
                }
                return (stored, present)
            }.value
            self.fonts = stored
            self.missingIDs = Set(stored.map(\.id)).subtracting(present)
            SubtitleFontFaces.invalidate()
        }
        loading = task
        await task.value

        var links: [String] = []
        for font in fonts where missingIDs.contains(font.id) {
            if let link = font.link, !links.contains(link) { links.append(link) }
        }
        guard !links.isEmpty else { return }
        Task { @MainActor in
            for link in links {
                _ = try? await self.add(link: link)
            }
        }
    }

    /// Saves the fonts in `data` (a font file, or a ZIP of them) and makes them usable at once.
    /// A font with the same PostScript name as one already added replaces it.
    @discardableResult
    func add(data: Data, fileName: String, link: String?) async throws -> [SubtitleFont] {
        await load()
        let saved = try await Task.detached(priority: .userInitiated) {
            try SubtitleFontLibrary.save(data, fileName: fileName, link: link)
        }.value
        install(saved)
        return saved
    }

    /// Downloads a font, a ZIP of fonts, or every style of a Google Fonts family.
    @discardableResult
    func add(link text: String) async throws -> [SubtitleFont] {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = SubtitleFontLinks.target(for: link) else { throw SubtitleFontError.badLink }
        switch target {
        case let .file(url):
            let data = try await SubtitleFontLinks.download(url)
            return try await add(data: data, fileName: url.lastPathComponent, link: link)
        case let .googleFonts(family):
            var added: [SubtitleFont] = []
            for url in try await SubtitleFontLinks.googleFontsFiles(family: family) {
                let data = try await SubtitleFontLinks.download(url)
                added += try await add(data: data, fileName: url.lastPathComponent, link: link)
            }
            return added
        }
    }

    func delete(_ font: SubtitleFont) {
        Self.unregisterAndDelete(font)
        fonts.removeAll { $0.id == font.id }
        missingIDs.remove(font.id)
        SubtitleFontFaces.invalidate()
        saveIndex()
        // A deleted font that was chosen for subtitles goes back to the system font.
        let store = ProfileSettings.current
        if let chosen = store.string(forKey: SubtitleStyleKey.fontName),
           font.families.contains(chosen), !familyNames.contains(chosen) {
            store.set(SubtitleStyleDefaults.fontName, forKey: SubtitleStyleKey.fontName)
        }
    }

    func delete(id: String) {
        guard let font = fonts.first(where: { $0.id == id }) else { return }
        delete(font)
    }

    private func install(_ saved: [SubtitleFont]) {
        let newNames = Set(saved.flatMap(\.postScriptNames))
        let replaced = fonts.filter { !Set($0.postScriptNames).isDisjoint(with: newNames) }
        for old in replaced {
            Self.unregisterAndDelete(old)
        }
        let replacedIDs = Set(replaced.map(\.id))
        fonts = fonts.filter { !replacedIDs.contains($0.id) } + saved
        missingIDs.subtract(replacedIDs)
        for font in saved {
            Self.register(Self.directory.appendingPathComponent(font.id))
        }
        SubtitleFontFaces.invalidate()
        saveIndex()
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(fonts) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    // MARK: Files

    nonisolated static func readIndex() -> [SubtitleFont] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([SubtitleFont].self, from: data)) ?? []
    }

    /// Writes each font of `data` to the fonts folder under a new name (a registered file is
    /// never overwritten) and describes it.
    nonisolated static func save(_ data: Data, fileName: String, link: String?) throws -> [SubtitleFont] {
        let files: [(name: String, data: Data)]
        switch SubtitleFontPayload.kind(of: data) {
        case .zip:
            files = try ZipFontArchive.fontEntries(
                in: data,
                limit: SubtitleFontLimits.fontsPerArchive,
                maximumEntryBytes: SubtitleFontLimits.fontBytes
            ).map { (name: $0.name, data: $0.data) }
            guard !files.isEmpty else { throw SubtitleFontError.noFontsInArchive }
        case .font:
            guard data.count <= SubtitleFontLimits.fontBytes else {
                throw SubtitleFontError.tooLarge(SubtitleFontLimits.fontBytes)
            }
            files = [(name: fileName, data: data)]
        case .webFont:
            throw SubtitleFontError.webFont
        case .webPage:
            throw SubtitleFontError.webPage
        case .unknown:
            throw SubtitleFontError.notAFont
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SubtitleFontError.couldNotSave(error.localizedDescription)
        }
        var saved: [SubtitleFont] = []
        for file in files {
            guard case let .font(fileExtension) = SubtitleFontPayload.kind(of: file.data) else { continue }
            let faces = SubtitleFontFaces.faces(in: file.data)
            guard let first = faces.first else { continue }
            let id = storedName(postScriptName: first.postScriptName, fileExtension: fileExtension)
            do {
                try file.data.write(to: directory.appendingPathComponent(id), options: .atomic)
            } catch {
                throw SubtitleFontError.couldNotSave(error.localizedDescription)
            }
            saved.append(SubtitleFont(
                id: id,
                families: unique(faces.map(\.family)),
                fullNames: unique(faces.map(\.fullName)),
                postScriptNames: faces.map(\.postScriptName),
                bytes: file.data.count,
                link: link,
                addedAt: Date()
            ))
        }
        guard !saved.isEmpty else {
            throw files.count > 1 ? SubtitleFontError.noFontsInArchive : SubtitleFontError.notAFont
        }
        return saved
    }

    /// "Roboto-Regular-k3m9qa.ttf": readable, and new each time.
    nonisolated static func storedName(postScriptName: String, fileExtension: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let base = String(postScriptName.unicodeScalars.filter { allowed.contains($0) }.prefix(60))
        let suffix = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
        return (base.isEmpty ? "font" : base) + "-" + suffix + "." + fileExtension
    }

    nonisolated static func register(_ url: URL) {
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        _ = error?.takeRetainedValue()
    }

    nonisolated static func unregisterAndDelete(_ font: SubtitleFont) {
        let url = directory.appendingPathComponent(font.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var error: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
        _ = error?.takeRetainedValue()
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
