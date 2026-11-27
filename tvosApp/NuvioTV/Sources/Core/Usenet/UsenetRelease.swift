import Foundation
import CryptoKit

/// One stretch of the played file: `length` bytes from `offset` inside volume `volume`.
struct UsenetExtent: Equatable, Sendable {
    var volume: Int
    var offset: Int64
    var length: Int64
}

/// What a stream session plays: the NZB files it reads articles from
/// (volumes) and where the played file's bytes sit in them. A plain video is
/// one volume and one extent; a stored RAR set is one extent per volume.
struct UsenetStreamSource: Sendable {
    enum Kind: String, Sendable {
        case plain
        case split
        case rar
        case sevenZip = "7z"
    }

    var name: String
    var kind: Kind
    var volumes: [UsenetFile]
    var extents: [UsenetExtent]
    /// Decoded first article of each volume (it gives the volume's layout).
    var firstArticles: [UsenetYEncSegment]
    /// A file stored encrypted in a password-protected RAR set: its stored bytes are
    /// decrypted as they are read.
    var cipher: UsenetRarCipher? = nil

    /// The bytes the extents hold: the file's own, or for an encrypted file the encrypted
    /// ones, padded to whole blocks.
    var storedSize: Int64 { extents.reduce(0) { $0 + $1.length } }

    /// The size of the played file.
    var totalSize: Int64 {
        guard let cipher else { return storedSize }
        return min(storedSize, max(0, cipher.plainSize))
    }

    /// Where each extent starts in the played file.
    var extentStarts: [Int64] {
        var starts: [Int64] = []
        var running: Int64 = 0
        for extent in extents {
            starts.append(running)
            running += extent.length
        }
        return starts
    }

    /// Ranges of a file this source maps (`ranges`, in its order) as extents of its volumes.
    static func compose(_ ranges: [Range<Int64>], through extents: [UsenetExtent]) -> [UsenetExtent] {
        let starts = UsenetStreamSource(name: "", kind: .plain, volumes: [], extents: extents, firstArticles: []).extentStarts
        var out: [UsenetExtent] = []
        for range in ranges {
            var position = range.lowerBound
            while position < range.upperBound, let place = locate(position, extents: extents, starts: starts) {
                let extent = extents[place.extent]
                let take = min(range.upperBound - position, starts[place.extent] + extent.length - position)
                if let last = out.last, last.volume == extent.volume, last.offset + last.length == place.volumeOffset {
                    out[out.count - 1].length += take
                } else {
                    out.append(UsenetExtent(volume: extent.volume, offset: place.volumeOffset, length: take))
                }
                position += take
            }
        }
        return out
    }

    /// The extent holding `offset` and the matching offset inside its volume.
    static func locate(_ offset: Int64, extents: [UsenetExtent], starts: [Int64]) -> (extent: Int, volumeOffset: Int64)? {
        guard offset >= 0, !extents.isEmpty else { return nil }
        var low = 0
        var high = extents.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        guard offset < starts[low] + extents[low].length else { return nil }
        return (low, extents[low].offset + (offset - starts[low]))
    }
}

/// Where a file stored in a RAR set sits, and how it is decrypted when the set is password
/// protected.
struct UsenetRarMapping: Sendable {
    var extents: [UsenetExtent]
    var cipher: UsenetRarCipher?
}

/// A 7z archive's volumes and file list.
struct UsenetSevenZipDetail: Sendable {
    /// First article of each volume.
    var heads: [UsenetYEncSegment]
    /// Each volume's place in the archive.
    var volumes: [UsenetExtent]
    var entries: [UsenetSevenZip.Entry]
}

/// A multi-file RAR set with every volume's headers read, in volume order.
struct UsenetRarSetDetail: Sendable {
    var parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)]
}

/// How an NZB file is treated, judged from its (possibly restored) name.
enum UsenetFileRole: Equatable, Sendable {
    case video
    case rar
    /// A raw split of a video (`movie.mkv.001`, `.002`, …).
    case split
    case par2
    /// A 7z archive, or a volume of one (`movie.7z`, `movie.7z.001`, …).
    case sevenZip
    /// An archive format that can't be streamed (zip, iso).
    case unsupportedArchive
    case sidecar
    /// No telling from the name: obfuscated, or an extension nobody uses.
    case unknown
}

/// A file the user could mean to play.
struct UsenetPlayableEntry: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case plain(Int)
        case split([Int])
        case rar([Int])
        /// A file of a RAR set stored inside the RAR set of these NZB files: its volumes are
        /// files of the outer set, by name, in order.
        case nestedRar([Int], volumes: [String])
        /// A file stored in the 7z archive these NZB files are the volumes of.
        case sevenZip([Int], file: String)
    }

    var name: String
    var source: Source
    /// Encoded bytes on Usenet, for "largest wins".
    var size: Int
    /// Position of its first file in the NZB, for `fileIdx`.
    var order: Int
}

/// Turns an NZB into a stream source: works out which files are what (also
/// for obfuscated releases), picks the video and maps RAR volumes.
struct UsenetReleaseResolver {
    let nzb: UsenetNZB
    let pool: UsenetConnectionPool
    let mustInclude: String?
    let fileIdx: Int?

    /// More files than this to identify means a broken or abusive NZB.
    private static let maxIdentified = 400

    func resolve() async throws -> UsenetStreamSource {
        let files = nzb.files
        var names = files.map(\.name)
        var roles = names.map(Self.role(ofName:))
        var heads: [Int: UsenetYEncSegment] = [:]
        var obfuscatedRar = Set<Int>()

        // 1. Obfuscated files: their first article tells what they are. Only
        //    worth it when the named files aren't already the bulk of the release.
        let unknown = files.indices.filter { roles[$0] == .unknown && !files[$0].segments.isEmpty }
        let namedBytes = files.indices.filter { [UsenetFileRole.video, .rar, .split, .sevenZip].contains(roles[$0]) }
            .reduce(0) { $0 + files[$1].encodedBytes }
        let unknownBytes = unknown.reduce(0) { $0 + files[$1].encodedBytes }
        if !unknown.isEmpty, namedBytes == 0 || unknownBytes > namedBytes {
            guard unknown.count <= Self.maxIdentified else { throw UsenetError.noPlayableFile }
            let fetched = try await fetchHeads(unknown)
            heads.merge(fetched) { current, _ in current }
            let restored = try await par2Names(roles: roles, heads: &heads)
            for index in unknown {
                guard let head = heads[index] else { continue }
                if head.fileOffset == 0, let name = restored[UsenetPar2.hash16k(head.data)] {
                    names[index] = name
                    roles[index] = Self.role(ofName: name)
                    usenetLog.notice("usenet: restored \(name, privacy: .public) from PAR2")
                    continue
                }
                if let name = head.header.name, Self.role(ofName: name) != .unknown {
                    names[index] = name
                    roles[index] = Self.role(ofName: name)
                    continue
                }
                switch UsenetSniff.kind(of: head.data) {
                case .video(let ext):
                    names[index] = "\(names[index]).\(ext)"
                    roles[index] = .video
                case .rar:
                    roles[index] = .rar
                    obfuscatedRar.insert(index)
                case .par2:
                    roles[index] = .par2
                case .sevenZip:
                    roles[index] = .sevenZip
                case .zip:
                    roles[index] = .unsupportedArchive
                case .unknown:
                    break
                }
            }
        }

        // 2. What could be played.
        var entries = Self.plainAndSplitEntries(files: files, names: names, roles: roles)
        var rarDetails: [[Int]: UsenetRarSetDetail] = [:]
        for set in Self.rarSets(names: names, roles: roles, obfuscated: obfuscatedRar) {
            entries += try await rarEntries(
                set, files: files, obfuscated: set.allSatisfy(obfuscatedRar.contains),
                heads: &heads, details: &rarDetails
            )
        }
        var sevenZipDetails: [[Int]: UsenetSevenZipDetail] = [:]
        var archiveProblem: UsenetError?
        for set in Self.sevenZipSets(names: names, roles: roles) {
            entries += try await sevenZipEntries(set, name: names[set[0]], heads: &heads,
                                                 details: &sevenZipDetails, problem: &archiveProblem)
        }
        entries.sort { $0.order < $1.order }

        guard let chosen = Self.choose(entries, mustInclude: mustInclude, fileIdx: fileIdx) else {
            if let mustInclude, !mustInclude.isEmpty, entries.count > 1 {
                // A pack without the wanted episode: never play another one instead.
                throw UsenetError.fileNotInPack
            }
            if let archiveProblem { throw archiveProblem }
            if let archive = files.indices.first(where: { roles[$0] == .unsupportedArchive }) {
                throw UsenetError.archiveNotSupported(names[archive])
            }
            throw UsenetError.noPlayableFile
        }
        usenetLog.notice("usenet: playing \(chosen.name, privacy: .public)")

        // 3. Map its bytes.
        switch chosen.source {
        case .plain(let index):
            let head = try await requireHeads([index], heads: &heads)[0]
            return UsenetStreamSource(
                name: chosen.name, kind: .plain, volumes: [files[index]],
                extents: [UsenetExtent(volume: 0, offset: 0, length: Self.fileSize(head))],
                firstArticles: [head]
            )
        case .split(let indices):
            let volumeHeads = try await requireHeads(indices, heads: &heads)
            let extents = volumeHeads.enumerated().map {
                UsenetExtent(volume: $0.offset, offset: 0, length: Self.fileSize($0.element))
            }
            return UsenetStreamSource(
                name: chosen.name, kind: .split, volumes: indices.map { files[$0] },
                extents: extents, firstArticles: volumeHeads
            )
        case .rar(let indices):
            var parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)] = []
            if let detail = rarDetails[indices] {
                // Multi-file set: every volume's headers were read already.
                parsed = detail.parsed
            } else {
                let volumeHeads = try await requireHeads(indices, heads: &heads)
                for (index, head) in zip(indices, volumeHeads) {
                    guard let volume = UsenetRar.parseVolume(head.data, password: nzb.password) else { throw UsenetError.releaseIncomplete }
                    parsed.append((index, head, volume))
                }
                if indices.allSatisfy(obfuscatedRar.contains) {
                    parsed = Self.orderObfuscated(parsed)
                }
            }
            let mapping = try Self.rarMapping(parsed.map { $0.volume }, innerName: chosen.name, password: nzb.password)
            return try rarSource(chosen.name, mapping: mapping, parsed: parsed)
        case .nestedRar(let indices, let innerNames):
            guard let parsed = rarDetails[indices]?.parsed, !parsed.isEmpty else { throw UsenetError.noPlayableFile }
            let outer = parsed.map(\.volume)
            let inner = try await innerVolumes(innerNames, outer: outer, parsed: parsed)
            let mapping = try Self.nestedMapping(outer: outer, innerNames: innerNames, inner: inner,
                                                 innerName: chosen.name, password: nzb.password)
            usenetLog.notice("usenet: RAR set inside a RAR set, \(innerNames.count) inner volumes")
            return try rarSource(chosen.name, mapping: mapping, parsed: parsed)
        case .sevenZip(let indices, let fileName):
            guard let detail = sevenZipDetails[indices] else { throw UsenetError.noPlayableFile }
            return try sevenZipSource(fileName, indices: indices, detail: detail)
        }
    }

    // MARK: - 7z

    /// 7z archives, by name: `x.7z` alone, or its volumes `x.7z.001`, `x.7z.002`, … in order. An
    /// obfuscated archive recognised by its bytes stands alone.
    static func sevenZipSets(names: [String], roles: [UsenetFileRole]) -> [[Int]] {
        var sets: [String: [(index: Int, number: Int)]] = [:]
        for index in names.indices where roles[index] == .sevenZip {
            let lower = names[index].lowercased()
            let ext = (lower as NSString).pathExtension
            if ext == "7z" {
                sets[lower, default: []].append((index, 0))
            } else if ext.count == 3, let number = Int(ext), (lower as NSString).deletingPathExtension.hasSuffix(".7z") {
                sets[(lower as NSString).deletingPathExtension, default: []].append((index, number))
            } else {
                sets["\u{0}\(index)", default: []].append((index, 0))
            }
        }
        return sets.values.map { $0.sorted { $0.number < $1.number }.map(\.index) }
            .sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }

    /// The videos stored in one 7z archive (its volumes `set`): its file list, read from the
    /// archive's end. What keeps a video from playing (compressed, a password) is kept in
    /// `problem` for when nothing else plays.
    private func sevenZipEntries(_ set: [Int], name: String, heads: inout [Int: UsenetYEncSegment],
                                 details: inout [[Int]: UsenetSevenZipDetail], problem: inout UsenetError?) async throws -> [UsenetPlayableEntry] {
        let volumeHeads = try await requireHeads(set, heads: &heads)
        let volumes = volumeHeads.enumerated().map { UsenetExtent(volume: $0.offset, offset: 0, length: Self.fileSize($0.element)) }
        let archiveSize = volumes.reduce(0) { $0 + $1.length }
        let entries: [UsenetSevenZip.Entry]
        do {
            let next = try UsenetSevenZip.nextHeader(volumeHeads[0].data)
            guard next.offset + Int64(next.size) <= archiveSize else { throw UsenetError.releaseIncomplete }
            let read: UsenetSevenZip.Reader = { offset, length in
                try await self.archiveBytes(set, heads: volumeHeads, volumes: volumes, offset: offset, length: length)
            }
            let header = try await read(next.offset, next.size)
            entries = try await UsenetSevenZip.entries(header: header, password: nzb.password, read: read)
        } catch let failure as UsenetSevenZip.Failure {
            switch failure {
            case .needsPassword: problem = problem ?? .archiveEncrypted
            case .wrongPassword: problem = problem ?? .wrongPassword
            case .notSevenZip, .damaged: problem = problem ?? .releaseIncomplete
            case .unsupported: problem = problem ?? .archiveNotSupported(name)
            }
            usenetLog.notice("usenet: 7z file list unreadable: \(String(describing: failure), privacy: .public)")
            return []
        }
        details[set] = UsenetSevenZipDetail(heads: volumeHeads, volumes: volumes, entries: entries)

        let baseOrder = (set.min() ?? 0) * 1000
        var playable: [UsenetPlayableEntry] = []
        for entry in entries where !entry.isDirectory && entry.size > 0 && Self.isVideoName(entry.name) {
            switch entry.method {
            case .stored:
                break
            case .encrypted:
                // Encrypted files are decrypted from their folder's start: a file further into a
                // solid folder would need everything before it.
                guard entry.offsetInFolder == 0, !(nzb.password ?? "").isEmpty else {
                    problem = problem ?? .archiveEncrypted
                    continue
                }
            case .compressed:
                problem = problem ?? .archiveCompressed(entry.name)
                continue
            }
            playable.append(UsenetPlayableEntry(name: entry.name, source: .sevenZip(set, file: entry.name),
                                                size: Int(clamping: entry.size), order: baseOrder + playable.count))
        }
        usenetLog.notice("usenet: 7z archive of \(set.count) volume(s) holds \(playable.count) playable videos")
        return playable
    }

    /// The stream of a file stored in a 7z archive.
    private func sevenZipSource(_ fileName: String, indices: [Int], detail: UsenetSevenZipDetail) throws -> UsenetStreamSource {
        guard let entry = detail.entries.first(where: { $0.name == fileName && !$0.isDirectory }) else {
            throw UsenetError.noPlayableFile
        }
        let start = entry.packStart + entry.offsetInFolder
        var storedLength = entry.size
        var cipher: UsenetRarCipher?
        if case .encrypted(let properties) = entry.method {
            guard let password = nzb.password, !password.isEmpty else { throw UsenetError.archiveEncrypted }
            do {
                cipher = try UsenetSevenZip.cipher(properties: properties, password: password, plainSize: entry.size)
            } catch {
                throw UsenetError.archiveEncrypted
            }
            // The whole folder: the file padded to AES blocks.
            storedLength = entry.packSize
        }
        let mapped = UsenetStreamSource.compose([start..<(start + storedLength)], through: detail.volumes)
        guard mapped.reduce(0, { $0 + $1.length }) == storedLength else { throw UsenetError.releaseIncomplete }
        if let cipher, let first = mapped.first,
           let head = Self.plainHead(of: detail.heads[first.volume], from: first, cipher: cipher),
           Self.passwordLooksWrong(name: fileName, plainHead: head) {
            throw UsenetError.wrongPassword
        }
        let used = Set(mapped.map(\.volume))
        let kept = detail.heads.indices.filter(used.contains)
        let remap = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
        return UsenetStreamSource(
            name: fileName, kind: .sevenZip,
            volumes: kept.map { nzb.files[indices[$0]] },
            extents: mapped.map { UsenetExtent(volume: remap[$0.volume]!, offset: $0.offset, length: $0.length) },
            firstArticles: kept.map { detail.heads[$0] },
            cipher: cipher
        )
    }

    /// `length` bytes of a 7z archive (its volumes joined) from `offset`.
    private func archiveBytes(_ set: [Int], heads: [UsenetYEncSegment], volumes: [UsenetExtent],
                              offset: Int64, length: Int) async throws -> Data {
        var out = Data()
        for piece in UsenetStreamSource.compose([offset..<(offset + Int64(length))], through: volumes) {
            guard let bytes = try await volumeBytes(nzb.files[set[piece.volume]], head: heads[piece.volume],
                                                    at: piece.offset, length: Int(piece.length)),
                  bytes.count == Int(piece.length) else { throw UsenetError.releaseIncomplete }
            out.append(bytes)
        }
        return out
    }

    /// The stream of a file mapped onto the volumes of a RAR set (`parsed`, in volume order).
    private func rarSource(_ name: String, mapping: UsenetRarMapping,
                           parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)]) throws -> UsenetStreamSource {
        let files = nzb.files
        let extents = mapping.extents
        let used = Set(extents.map(\.volume))
        let kept = parsed.indices.filter(used.contains)
        let remap = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
        if let cipher = mapping.cipher {
            if !cipher.passwordChecked, let first = extents.first,
               let head = Self.plainHead(of: parsed[first.volume].head, from: first, cipher: cipher),
               Self.passwordLooksWrong(name: name, plainHead: head) {
                throw UsenetError.wrongPassword
            }
            usenetLog.notice("usenet: encrypted RAR, opened with the NZB's password")
        }
        return UsenetStreamSource(
            name: name, kind: .rar,
            volumes: kept.map { files[parsed[$0].index] },
            extents: extents.map { UsenetExtent(volume: remap[$0.volume]!, offset: $0.offset, length: $0.length) },
            firstArticles: kept.map { parsed[$0].head },
            cipher: mapping.cipher
        )
    }

    // MARK: - RAR inside RAR

    /// The inner volumes' headers, from the first bytes of each one in the outer set, read in
    /// parallel.
    private func innerVolumes(_ names: [String], outer: [UsenetRarVolume],
                              parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)]) async throws -> [UsenetRarVolume] {
        let password = nzb.password
        let placed = try names.map { try Self.rarMapping(outer, innerName: $0, password: password).extents }
        return try await withThrowingTaskGroup(of: (Int, UsenetRarVolume?).self, returning: [UsenetRarVolume].self) { group in
            var result = [UsenetRarVolume?](repeating: nil, count: names.count)
            var pending = names.indices.makeIterator()
            for _ in 0..<8 {
                guard let index = pending.next() else { break }
                group.addTask {
                    let bytes = try await self.storedBytes(placed[index], parsed: parsed, length: Self.innerHeaderBytes)
                    return (index, UsenetRar.parseVolume(bytes, password: password))
                }
            }
            while let finished = try await group.next() {
                result[finished.0] = finished.1
                if let index = pending.next() {
                    group.addTask {
                        let bytes = try await self.storedBytes(placed[index], parsed: parsed, length: Self.innerHeaderBytes)
                        return (index, UsenetRar.parseVolume(bytes, password: password))
                    }
                }
            }
            return try result.map { volume in
                guard let volume else { throw UsenetError.releaseIncomplete }
                return volume
            }
        }
    }

    /// An inner volume's headers fit in its first bytes (a scene volume's take a few hundred).
    static let innerHeaderBytes = 32 * 1024

    /// The first `length` bytes of a file stored in a RAR set (at `extents` of its volumes).
    private func storedBytes(_ extents: [UsenetExtent], parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)],
                             length: Int) async throws -> Data {
        var out = Data()
        for extent in extents where out.count < length {
            let wanted = Int(min(Int64(length - out.count), extent.length))
            let volume = parsed[extent.volume]
            guard let bytes = try await volumeBytes(nzb.files[volume.index], head: volume.head, at: extent.offset, length: wanted),
                  !bytes.isEmpty else { break }
            out.append(bytes)
            if bytes.count < wanted { break }
        }
        return out
    }

    /// The RAR sets among the files of an outer set, each in volume order.
    static func innerRarSets(_ names: [String]) -> [[String]] {
        var sets: [String: [(name: String, number: Int)]] = [:]
        var order: [String] = []
        for name in names where role(ofName: name) == .rar {
            guard let key = rarVolumeKey(name) else { continue }
            if sets[key.set] == nil { order.append(key.set) }
            sets[key.set, default: []].append((name, key.number))
        }
        return order.compactMap { sets[$0]?.sorted { $0.number < $1.number }.map(\.name) }
    }

    /// A file of a RAR set stored inside another RAR set (`outer`, whose files `innerNames` are
    /// the inner set's volumes `inner`): where its bytes sit in the outer volumes.
    static func nestedMapping(outer: [UsenetRarVolume], innerNames: [String], inner: [UsenetRarVolume],
                              innerName: String, password: String?) throws -> UsenetRarMapping {
        let mapping = try rarMapping(inner, innerName: innerName, password: password)
        var placed: [Int: [UsenetExtent]] = [:]
        var extents: [UsenetExtent] = []
        for extent in mapping.extents {
            guard innerNames.indices.contains(extent.volume) else { throw UsenetError.releaseIncomplete }
            if placed[extent.volume] == nil {
                let volume = try rarMapping(outer, innerName: innerNames[extent.volume], password: password)
                // An encrypted outer set would need decrypting before the inner one is read.
                guard volume.cipher == nil else { throw UsenetError.archiveEncrypted }
                placed[extent.volume] = volume.extents
            }
            let pieces = UsenetStreamSource.compose([extent.offset..<(extent.offset + extent.length)], through: placed[extent.volume] ?? [])
            guard pieces.reduce(0, { $0 + $1.length }) == extent.length else { throw UsenetError.releaseIncomplete }
            for piece in pieces {
                if let last = extents.last, last.volume == piece.volume, last.offset + last.length == piece.offset {
                    extents[extents.count - 1].length += piece.length
                } else {
                    extents.append(piece)
                }
            }
        }
        return UsenetRarMapping(extents: extents, cipher: mapping.cipher)
    }

    // MARK: - Names and roles

    static let sidecarExtensions: Set<String> = [
        "sfv", "nfo", "nzb", "srr", "srs", "jpg", "jpeg", "png", "txt", "url", "md5", "sha1", "db",
        "srt", "ass", "ssa", "sub", "idx", "sup", "vtt", "exe", "lnk", "html", "htm",
    ]

    static func role(ofName name: String) -> UsenetFileRole {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if UsenetFile.videoExtensions.contains(ext) { return .video }
        if ext == "par2" { return .par2 }
        if ext == "rar" { return .rar }
        if ext.count == 3, ext.hasPrefix("r"), Int(ext.dropFirst()) != nil { return .rar }
        if ext.count == 3, Int(ext) != nil {
            let inner = ((lower as NSString).deletingPathExtension as NSString).pathExtension
            if UsenetFile.videoExtensions.contains(inner) { return .split }
            if inner == "7z" { return .sevenZip }
            if inner == "zip" { return .unsupportedArchive }
            if inner == "rar" { return .rar }
            return .unknown
        }
        if ext == "7z" { return .sevenZip }
        if ["zip", "iso", "img"].contains(ext) { return .unsupportedArchive }
        if sidecarExtensions.contains(ext) { return .sidecar }
        return .unknown
    }

    /// The set a RAR volume belongs to and its place in it: `x.part03.rar`
    /// → ("x", 3); `x.rar` → ("x", 0); `x.r00` → ("x", 1); `x.rar.001` → ("x", 1).
    static func rarVolumeKey(_ name: String) -> (set: String, number: Int)? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        let base = (lower as NSString).deletingPathExtension
        if ext == "rar" {
            let partExt = (base as NSString).pathExtension
            if partExt.hasPrefix("part"), let number = Int(partExt.dropFirst(4)) {
                return ((base as NSString).deletingPathExtension, number)
            }
            return (base, 0)
        }
        if ext.count == 3, ext.hasPrefix("r"), let number = Int(ext.dropFirst()) {
            return (base, number + 1)
        }
        if ext.count == 3, let number = Int(ext), (base as NSString).pathExtension == "rar" {
            return ((base as NSString).deletingPathExtension, number)
        }
        return nil
    }

    static func plainAndSplitEntries(files: [UsenetFile], names: [String], roles: [UsenetFileRole]) -> [UsenetPlayableEntry] {
        var entries: [UsenetPlayableEntry] = []
        var splits: [String: [(index: Int, number: Int)]] = [:]
        for index in files.indices {
            switch roles[index] {
            case .video:
                entries.append(UsenetPlayableEntry(name: names[index], source: .plain(index), size: files[index].encodedBytes, order: index * 1000))
            case .split:
                let base = (names[index] as NSString).deletingPathExtension
                let number = Int((names[index] as NSString).pathExtension) ?? 0
                splits[base, default: []].append((index, number))
            default:
                break
            }
        }
        for (base, parts) in splits {
            let ordered = parts.sorted { $0.number < $1.number }.map { $0.index }
            entries.append(UsenetPlayableEntry(
                name: base, source: .split(ordered),
                size: ordered.reduce(0) { $0 + files[$1].encodedBytes },
                order: (ordered.min() ?? 0) * 1000
            ))
        }
        return entries
    }

    /// RAR volumes grouped into sets, each in volume order. Obfuscated
    /// volumes (recognised only by their bytes) form one set in NZB order
    /// until their headers are read.
    static func rarSets(names: [String], roles: [UsenetFileRole], obfuscated: Set<Int>) -> [[Int]] {
        var sets: [String: [(index: Int, number: Int)]] = [:]
        var anonymous: [Int] = []
        for index in names.indices where roles[index] == .rar {
            if obfuscated.contains(index) {
                anonymous.append(index)
            } else if let key = rarVolumeKey(names[index]) {
                sets[key.set, default: []].append((index, key.number))
            } else {
                anonymous.append(index)
            }
        }
        var result = sets.values.map { $0.sorted { $0.number < $1.number }.map { $0.index } }
        if !anonymous.isEmpty { result.append(anonymous) }
        return result.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }

    /// Volume order for obfuscated RAR sets: RAR 5 numbers its volumes, RAR 4
    /// only flags the first one, so the rest keep their NZB order.
    static func orderObfuscated<T>(_ volumes: [(index: Int, head: T, volume: UsenetRarVolume)]) -> [(index: Int, head: T, volume: UsenetRarVolume)] {
        if volumes.allSatisfy({ $0.volume.volumeNumber != nil }) {
            return volumes.sorted { ($0.volume.volumeNumber ?? 0) < ($1.volume.volumeNumber ?? 0) }
        }
        guard let first = volumes.firstIndex(where: { $0.volume.isFirstVolume == true }), first > 0 else { return volumes }
        var ordered = volumes
        let head = ordered.remove(at: first)
        ordered.insert(head, at: 0)
        return ordered
    }

    /// Where a stored file's bytes sit across the volumes of its set.
    static func rarExtents(_ volumes: [UsenetRarVolume], innerName: String) throws -> [UsenetExtent] {
        try rarMapping(volumes, innerName: innerName, password: nil).extents
    }

    /// Where a stored file's bytes sit across the volumes of its set, and the key they are
    /// decrypted with when the set is password protected (`password`: the NZB's).
    static func rarMapping(_ volumes: [UsenetRarVolume], innerName: String, password: String?) throws -> UsenetRarMapping {
        guard !volumes.isEmpty else { throw UsenetError.noPlayableFile }
        if volumes.contains(where: \.headersEncrypted) {
            throw volumes.contains(where: \.passwordRejected) ? UsenetError.wrongPassword : UsenetError.archiveEncrypted
        }
        // In a multi-file set the wanted file can start in any volume.
        let startsHere: (UsenetRarEntry) -> Bool = { $0.name == innerName && !$0.continuesFromPrevious }
        guard let startVolume = volumes.firstIndex(where: { $0.entries.contains(where: startsHere) }),
              let firstEntry = volumes[startVolume].entries.first(where: startsHere) else {
            throw UsenetError.noPlayableFile
        }
        if firstEntry.isEncrypted, (password?.isEmpty ?? true) || firstEntry.encryption == nil {
            throw UsenetError.archiveEncrypted
        }
        guard firstEntry.isStored else { throw UsenetError.archiveCompressed(innerName) }

        var extents = [UsenetExtent(volume: startVolume, offset: firstEntry.dataOffset, length: firstEntry.packedSize)]
        var continues = firstEntry.continuesInNext
        var volume = startVolume + 1
        while continues, volume < volumes.count {
            guard let part = volumes[volume].entries.first(where: { $0.name == innerName && $0.continuesFromPrevious }) else {
                throw UsenetError.releaseIncomplete
            }
            if part.isEncrypted != firstEntry.isEncrypted { throw UsenetError.archiveEncrypted }
            extents.append(UsenetExtent(volume: volume, offset: part.dataOffset, length: part.packedSize))
            continues = part.continuesInNext
            volume += 1
        }
        let total = extents.reduce(0) { $0 + $1.length }
        if continues || (firstEntry.unpackedSize > 0 && total < firstEntry.unpackedSize) {
            // Volumes are missing from the NZB.
            throw UsenetError.releaseIncomplete
        }
        var cipher: UsenetRarCipher?
        if firstEntry.isEncrypted, let password, let encryption = firstEntry.encryption {
            let plainSize = firstEntry.unpackedSize >= 0 ? firstEntry.unpackedSize : total
            cipher = try UsenetRarCrypto.cipher(for: encryption, password: password, plainSize: plainSize)
        }
        return UsenetRarMapping(extents: extents.filter { $0.length > 0 }, cipher: cipher)
    }

    /// The first plain bytes of an encrypted file, when the first article of its first volume
    /// holds them.
    static func plainHead(of article: UsenetYEncSegment, from extent: UsenetExtent, cipher: UsenetRarCipher) -> Data? {
        let begin = Int64(article.fileOffset)
        let from = extent.offset - begin
        let length = Int(min(extent.length, 1024, Int64(article.data.count) - from)) / 16 * 16
        guard from >= 0, length >= 16 else { return nil }
        let start = article.data.startIndex + Int(from)
        let stored = article.data.subdata(in: start..<(start + length))
        return UsenetRarCrypto.plain(stored, storedStart: 0, previous: nil, cipher: cipher, offset: 0, length: length)
    }

    /// A video that doesn't start the way its kind does: the archive's password (which RAR 4
    /// can't check) decrypted it into noise.
    static func passwordLooksWrong(name: String, plainHead: Data) -> Bool {
        let sniffable = ["mkv", "webm", "mp4", "m4v", "avi", "ts", "m2ts"]
        guard sniffable.contains((name as NSString).pathExtension.lowercased()), plainHead.count >= 400 else { return false }
        return UsenetSniff.kind(of: plainHead) == .unknown
    }

    /// Stremio examples write `fileMustInclude` like a JavaScript literal,
    /// `/E05|- 05/i`; the slashes and flags are dropped (matching is always
    /// case-insensitive). Anything else is used as it is.
    static func normalizedPattern(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("/"),
              let close = trimmed.lastIndex(of: "/"), close > trimmed.startIndex else { return trimmed }
        let flags = trimmed[trimmed.index(after: close)...]
        guard flags.allSatisfy({ "gimsuy".contains($0) }) else { return trimmed }
        let body = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        return body.isEmpty ? trimmed : body
    }

    /// `fileMustInclude` (a regex, case-insensitive) wins, then `fileIdx`
    /// among the entries in NZB order, then the largest entry.
    static func choose(_ entries: [UsenetPlayableEntry], mustInclude: String?, fileIdx: Int?) -> UsenetPlayableEntry? {
        let candidates = entries.filter { !isSample($0.name) || entries.count == 1 }
        if let mustInclude, !mustInclude.isEmpty {
            let regex = try? NSRegularExpression(pattern: mustInclude, options: [.caseInsensitive])
            let matches: (String) -> Bool = { name in
                if let regex {
                    return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                }
                return name.localizedCaseInsensitiveContains(mustInclude)
            }
            if let match = entries.first(where: { matches($0.name) }) { return match }
            // Several files and none is the wanted one: let the caller fail.
            if candidates.count > 1 { return nil }
        }
        if let fileIdx, entries.indices.contains(fileIdx) { return entries[fileIdx] }
        return (candidates.isEmpty ? entries : candidates).max { $0.size < $1.size }
    }

    private static func isSample(_ name: String) -> Bool {
        if DebridVideo.isSample(name) { return true }
        let filename = name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? ""
        let stem = (filename as NSString).deletingPathExtension
        // Require a trailing trailer label, rather than matching a title such
        // as Trailer Park Boys anywhere in the file or parent directory.
        return stem.range(
            of: #"(?i)(?:^|[.\s_-])trailer$"#,
            options: .regularExpression
        ) != nil
    }

    private static func fileSize(_ head: UsenetYEncSegment) -> Int64 {
        Int64(head.header.size ?? head.data.count)
    }

    // MARK: - Fetching first articles

    /// The videos inside one RAR set. A set holding one big file is judged
    /// from its first volume; a set whose first file is much smaller than the
    /// set (a season packed in one archive) has every volume's headers read,
    /// including headers that sit mid-volume after the previous file's data.
    private func rarEntries(
        _ set: [Int], files: [UsenetFile], obfuscated: Bool,
        heads: inout [Int: UsenetYEncSegment], details: inout [[Int]: UsenetRarSetDetail]
    ) async throws -> [UsenetPlayableEntry] {
        guard let first = set.first else { return [] }
        let baseOrder = (set.min() ?? first) * 1000
        let setBytes = set.reduce(0) { $0 + files[$1].encodedBytes }

        // Obfuscated sets: find the first volume among them.
        var leader = first
        if heads[first] != nil, set.count > 1 {
            let volumes = set.compactMap { index in
                heads[index].flatMap { UsenetRar.parseVolume($0.data, password: nzb.password) }.map { (index, $0) }
            }
            if let firstVolume = volumes.first(where: { $0.1.isFirstVolume == true || $0.1.volumeNumber == 0 }) {
                leader = firstVolume.0
            }
        }
        guard let head = try await requireHeads([leader], heads: &heads).first,
              let volume = UsenetRar.parseVolume(head.data, password: nzb.password) else { return [] }

        let listed = volume.entries.filter { !$0.isDirectory && !$0.continuesFromPrevious }
            .reduce(Int64(0)) { $0 + max(0, $1.unpackedSize) }
        // A set holding another RAR set's volumes is always listed: they are found by name.
        let wrapsRar = volume.entries.contains { !$0.isDirectory && Self.role(ofName: $0.name) == .rar }
        let isMultiFile = (Self.isMultiFileSet(listedBytes: listed, encodedSetBytes: setBytes) || wrapsRar)
            && !volume.headersEncrypted

        if !isMultiFile {
            let videos = volume.entries.filter { !$0.isDirectory && Self.isVideoName($0.name) }
            guard let inner = videos.max(by: { $0.unpackedSize < $1.unpackedSize }) else { return [] }
            return [UsenetPlayableEntry(name: inner.name, source: .rar(set), size: setBytes, order: baseOrder)]
        }

        let volumeHeads = try await requireHeads(set, heads: &heads)
        var parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)] = []
        for (index, volumeHead) in zip(set, volumeHeads) {
            guard let parsedVolume = UsenetRar.parseVolume(volumeHead.data, password: nzb.password) else { throw UsenetError.releaseIncomplete }
            parsed.append((index, volumeHead, parsedVolume))
        }
        if obfuscated { parsed = Self.orderObfuscated(parsed) }
        parsed = try await completeAllHeaders(parsed, files: files)
        details[set] = UsenetRarSetDetail(parsed: parsed)

        let stored = parsed.flatMap { $0.volume.entries }.filter { !$0.isDirectory && !$0.continuesFromPrevious }
        let starts = stored.filter { Self.isVideoName($0.name) }
        usenetLog.notice("usenet: RAR set holds \(starts.count) videos")
        var entries = starts.enumerated().map { number, entry in
            UsenetPlayableEntry(
                name: entry.name, source: .rar(set),
                size: Int(clamping: max(0, entry.unpackedSize)),
                order: baseOrder + number
            )
        }
        // RAR sets stored inside this one: the videos their first volume lists.
        let outer = parsed.map(\.volume)
        for innerNames in Self.innerRarSets(stored.map(\.name)) {
            guard let firstName = innerNames.first,
                  let extents = try? Self.rarMapping(outer, innerName: firstName, password: nzb.password).extents,
                  let bytes = try? await storedBytes(extents, parsed: parsed, length: Self.innerHeaderBytes),
                  let inner = UsenetRar.parseVolume(bytes, password: nzb.password) else { continue }
            let videos = inner.entries.filter { !$0.isDirectory && !$0.continuesFromPrevious && Self.isVideoName($0.name) }
            usenetLog.notice("usenet: RAR set inside the set, \(innerNames.count) volumes, \(videos.count) videos")
            for video in videos {
                entries.append(UsenetPlayableEntry(
                    name: video.name, source: .nestedRar(set, volumes: innerNames),
                    size: Int(clamping: max(0, video.unpackedSize)),
                    order: baseOrder + entries.count
                ))
            }
        }
        return entries
    }

    /// Reads every volume's remaining headers, several volumes at a time.
    private func completeAllHeaders(_ parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)],
                                    files: [UsenetFile]) async throws -> [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)] {
        var result = parsed
        let completed = try await withThrowingTaskGroup(of: (Int, UsenetRarVolume).self, returning: [Int: UsenetRarVolume].self) { group in
            var done: [Int: UsenetRarVolume] = [:]
            var pending = parsed.indices.makeIterator()
            for _ in 0..<8 {
                guard let k = pending.next() else { break }
                group.addTask { (k, try await self.completeHeaders(parsed[k].volume, file: files[parsed[k].index], head: parsed[k].head)) }
            }
            while let finished = try await group.next() {
                done[finished.0] = finished.1
                if let k = pending.next() {
                    group.addTask { (k, try await self.completeHeaders(parsed[k].volume, file: files[parsed[k].index], head: parsed[k].head)) }
                }
            }
            return done
        }
        for (k, volume) in completed { result[k].volume = volume }
        return result
    }

    /// A first file under 85 % of the set means more files follow it
    /// (yEnc adds roughly 2–3 %, a single big file covers nearly all of it).
    static func isMultiFileSet(listedBytes: Int64, encodedSetBytes: Int) -> Bool {
        guard encodedSetBytes > 0 else { return false }
        let estimatedDecoded = Double(encodedSetBytes) / 1.03
        return Double(listedBytes) < estimatedDecoded * 0.85
    }

    static func isVideoName(_ name: String) -> Bool {
        UsenetFile.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Reads the headers that sit after the previous file's data, until the
    /// volume's end (a few KB of trailer or recovery data is not a file).
    private func completeHeaders(_ start: UsenetRarVolume, file: UsenetFile, head: UsenetYEncSegment) async throws -> UsenetRarVolume {
        var volume = start
        let size = Int64(head.header.size ?? head.data.count)
        var rounds = 0
        while !volume.reachedEnd, !volume.headersEncrypted,
              let offset = volume.pendingHeaderOffset, size - offset > 4096, rounds < 64 {
            rounds += 1
            guard let bytes = try await volumeBytes(file, head: head, at: offset, length: 64 * 1024),
                  !bytes.isEmpty else { break }
            UsenetRar.continueVolume(&volume, bytes: bytes, at: offset)
            if volume.pendingHeaderOffset == offset { break }   // no progress
        }
        return volume
    }

    /// `length` bytes of a volume from `offset`, fetching the articles that hold them.
    private func volumeBytes(_ file: UsenetFile, head: UsenetYEncSegment, at offset: Int64, length: Int) async throws -> Data? {
        let size = Int64(head.header.size ?? head.data.count)
        let begin = Int64(head.fileOffset)
        var layout = UsenetFileLayout(
            totalSize: size,
            firstPart: begin..<(begin + Int64(head.data.count)),
            segments: file.segments
        )
        var out = Data()
        var position = offset
        var probe = layout.index(for: position)
        var hops = 0
        while out.count < length, position < size, hops < 24 {
            hops += 1
            let article: UsenetYEncSegment
            if probe.index == 0 {
                article = head
            } else {
                guard case .body(let body) = try await pool.fetch(messageID: file.segments[probe.index].messageID),
                      let decoded = try? UsenetYEnc.decode(body: body) else { break }
                article = decoded
            }
            let start = Int64(article.fileOffset)
            let range = start..<(start + Int64(article.data.count))
            layout.learn(probe.index, range: range)
            if range.contains(position) {
                let from = Int(position - start)
                let take = min(article.data.count - from, length - out.count)
                out.append(article.data.subdata(in: from..<(from + take)))
                position += Int64(take)
                guard probe.index + 1 < file.segments.count else { break }
                probe = (probe.index + 1, true)
            } else {
                let next = position < range.lowerBound ? probe.index - 1 : probe.index + 1
                guard next >= 0, next < file.segments.count else { break }
                probe = (next, false)
            }
        }
        return out.isEmpty ? nil : out
    }

    private func requireHeads(_ indices: [Int], heads: inout [Int: UsenetYEncSegment]) async throws -> [UsenetYEncSegment] {
        let missing = indices.filter { heads[$0] == nil }
        if !missing.isEmpty {
            let fetched = try await fetchHeads(missing)
            heads.merge(fetched) { current, _ in current }
        }
        return try indices.map { index in
            guard let head = heads[index] else {
                throw indices.count == 1 ? UsenetError.firstSegmentUnavailable : UsenetError.releaseIncomplete
            }
            return head
        }
    }

    /// Decoded first articles of the given files, fetched in parallel.
    private func fetchHeads(_ indices: [Int]) async throws -> [Int: UsenetYEncSegment] {
        let files = nzb.files
        let pool = self.pool
        let limit = max(2, pool.totalConnections)
        return try await withThrowingTaskGroup(of: (Int, UsenetYEncSegment?).self, returning: [Int: UsenetYEncSegment].self) { group in
            var result: [Int: UsenetYEncSegment] = [:]
            var pending = indices.makeIterator()
            for _ in 0..<limit {
                guard let index = pending.next() else { break }
                group.addTask { (index, try await Self.head(of: files[index], pool: pool)) }
            }
            while let finished = try await group.next() {
                if let head = finished.1 { result[finished.0] = head }
                if let index = pending.next() {
                    group.addTask { (index, try await Self.head(of: files[index], pool: pool)) }
                }
            }
            return result
        }
    }

    private static func head(of file: UsenetFile, pool: UsenetConnectionPool) async throws -> UsenetYEncSegment? {
        guard let first = file.segments.first,
              case .body(let body) = try await pool.fetch(messageID: first.messageID) else { return nil }
        return try? await Task.detached(priority: .userInitiated) {
            try UsenetYEnc.decode(body: body)
        }.value
    }

    /// Real names by 16 KiB hash, from the smallest PAR2 file in the release.
    private func par2Names(roles: [UsenetFileRole], heads: inout [Int: UsenetYEncSegment]) async throws -> [Data: String] {
        let files = nzb.files
        var candidates = files.indices.filter { roles[$0] == .par2 }
        candidates += heads.filter { UsenetPar2.isPar2($0.value.data) }.map(\.key)
        guard let index = Set(candidates).min(by: { files[$0].encodedBytes < files[$1].encodedBytes }),
              files[index].segments.count <= 8 else { return [:] }
        // The index PAR2 is small: read all of it.
        var data = Data()
        for segment in files[index].segments {
            if segment.number == files[index].segments.first?.number, let head = heads[index] {
                data.append(head.data)
                continue
            }
            guard case .body(let body) = try await pool.fetch(messageID: segment.messageID),
                  let decoded = try? UsenetYEnc.decode(body: body) else { break }
            data.append(decoded.data)
        }
        var names: [Data: String] = [:]
        for description in UsenetPar2.fileDescriptions(in: data) {
            names[description.hash16k] = description.name
        }
        return names
    }
}

// MARK: - Availability check

/// Asks the servers (STAT, no download) whether a sample of the release's
/// articles still exists, so an incomplete upload fails in a second instead
/// of half an hour into the film.
enum UsenetHealthCheck {
    static let sampleCount = 12

    struct Result: Equatable {
        var checked: Int
        var missing: Int
        var tailMissing: Bool
    }

    static func samples(for source: UsenetStreamSource) -> [String] {
        // Every article except each volume's first (already downloaded).
        let ids = source.volumes.flatMap { $0.segments.dropFirst().map(\.messageID) }
        guard !ids.isEmpty else { return [] }
        let count = min(sampleCount, ids.count)
        var picked: [String] = []
        for step in 0..<count {
            let position = count == 1 ? ids.count - 1 : step * (ids.count - 1) / (count - 1)
            picked.append(ids[position])
        }
        return picked
    }

    static func check(_ source: UsenetStreamSource, pool: UsenetConnectionPool) async throws -> Result {
        let ids = samples(for: source)
        guard let tail = ids.last else { return Result(checked: 0, missing: 0, tailMissing: false) }
        let found = try await withThrowingTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for id in ids {
                group.addTask { (id, try await pool.exists(messageID: id)) }
            }
            var results: [String: Bool] = [:]
            for try await answer in group { results[answer.0] = answer.1 }
            return results
        }
        let missing = found.values.filter { !$0 }.count
        return Result(checked: ids.count, missing: missing, tailMissing: found[tail] == false)
    }

    /// One missing sample is a glitch the player skips; more, or a missing
    /// end of file, means a broken release.
    static func isPlayable(_ result: Result) -> Bool {
        !result.tailMissing && result.missing < 2
    }
}

// MARK: - NZB cache

/// Downloaded NZBs on disk for 14 days (256 MB at most), so resuming or
/// replaying doesn't wait for the indexer.
enum UsenetNZBCache {
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    static let maxBytes = 256 << 20

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsenetNZB", isDirectory: true)
    }

    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func cached(_ url: URL) -> Data? {
        let file = directory.appendingPathComponent(key(for: url))
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: file) else { return nil }
        return data
    }

    static func store(_ data: Data, for url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key(for: url)), options: .atomic)
        prune()
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key(for: url)))
    }

    static func prune() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        let now = Date()
        for entry in entries where now.timeIntervalSince(entry.date) >= maxAge {
            try? fileManager.removeItem(at: entry.url)
        }
        entries.removeAll { now.timeIntervalSince($0.date) >= maxAge }
        entries.sort { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > maxBytes {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
