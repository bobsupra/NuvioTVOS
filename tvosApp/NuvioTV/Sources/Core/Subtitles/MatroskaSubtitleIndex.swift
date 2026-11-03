import Foundation

/// Byte ranges of the playing file. `totalSize` is the file's length when the source told it.
protocol SubtitleIndexByteSource: Sendable {
    func read(offset: Int64, length: Int) async throws -> (data: Data, totalSize: Int64?)
}

enum SubtitleIndexError: Error, Equatable {
    case notMatroska
    case noIndex
    case noSubtitleTracks
    /// The file's track list couldn't be found (no SeekHead entry, not in the head).
    case tracksNotFound
    case rangeUnsupported
    case budgetExceeded
}

/// A subtitle track of a Matroska file and when its frames show, from the file's Cues index.
struct MatroskaSubtitleTrack: Equatable, Sendable {
    let number: UInt64
    let codecID: String
    let language: String?
    let name: String?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isCommentary: Bool
    /// Start and (when the index has it) length of each indexed frame, in seconds.
    var events: [(start: Double, duration: Double?)]

    static func == (lhs: MatroskaSubtitleTrack, rhs: MatroskaSubtitleTrack) -> Bool {
        lhs.number == rhs.number && lhs.codecID == rhs.codecID && lhs.language == rhs.language
            && lhs.name == rhs.name && lhs.isDefault == rhs.isDefault && lhs.isForced == rhs.isForced
            && lhs.isHearingImpaired == rhs.isHearingImpaired && lhs.isCommentary == rhs.isCommentary
            && lhs.events.count == rhs.events.count
            && zip(lhs.events, rhs.events).allSatisfy { $0.start == $1.start && $0.duration == $1.duration }
    }

    var isText: Bool { codecID.hasPrefix("S_TEXT/") }
    var isASS: Bool { codecID == "S_TEXT/ASS" || codecID == "S_TEXT/SSA" }
    var isPGS: Bool { codecID == "S_HDMV/PGS" }

    /// What the debug HUD calls this track ("ASS eng", "PGS cze Full").
    var summary: String {
        let kind = isASS ? "ASS" : (isPGS ? "PGS" : codecID.replacingOccurrences(of: "S_TEXT/", with: ""))
        return [kind, language, name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
    }
}

/// Reads a Matroska file's subtitle tracks and their timing from its Cues, with a few range
/// requests: the header, the SeekHead, Info, Tracks and Cues. A remux indexes every subtitle
/// frame, so the whole subtitle timeline is known without playing the file (a 1.4 GB episode
/// took about 90 kB). Measured on TorBox files for the anime subtitle retiming.
struct MatroskaSubtitleIndex: Sendable {
    var tracks: [MatroskaSubtitleTrack]
    /// What reading the index took (for the diagnostics).
    var requests = 0
    var bytes: Int64 = 0

    static let headBytes = 256 * 1024
    static let maxInfoBytes = 512 * 1024
    static let maxTracksBytes = 4 * 1024 * 1024
    static let maxCuesBytes = 8 * 1024 * 1024
    static let tailScanBytes = 2 * 1024 * 1024
    static let maxTotalBytes: Int64 = 24 * 1024 * 1024
    static let maxRequests = 16

    // Element IDs (with their length marker, as written in the file).
    static let ebmlID: UInt32 = 0x1A45DFA3
    static let segmentID: UInt32 = 0x18538067
    static let seekHeadID: UInt32 = 0x114D9B74
    static let seekID: UInt32 = 0x4DBB
    static let seekElementID: UInt32 = 0x53AB
    static let seekPositionID: UInt32 = 0x53AC
    static let infoID: UInt32 = 0x1549A966
    static let timestampScaleID: UInt32 = 0x2AD7B1
    static let tracksID: UInt32 = 0x1654AE6B
    static let trackEntryID: UInt32 = 0xAE
    static let trackNumberID: UInt32 = 0xD7
    static let trackTypeID: UInt32 = 0x83
    static let codecIDID: UInt32 = 0x86
    static let languageID: UInt32 = 0x22B59C
    static let languageBCP47ID: UInt32 = 0x22B59D
    static let nameID: UInt32 = 0x536E
    static let flagDefaultID: UInt32 = 0x88
    static let flagForcedID: UInt32 = 0x55AA
    static let flagHearingImpairedID: UInt32 = 0x55AB
    static let flagCommentaryID: UInt32 = 0x55AF
    static let cuesID: UInt32 = 0x1C53BB6B
    static let cuePointID: UInt32 = 0xBB
    static let cueTimeID: UInt32 = 0xB3
    static let cueTrackPositionsID: UInt32 = 0xB7
    static let cueTrackID: UInt32 = 0xF7
    static let cueDurationID: UInt32 = 0xB2
    static let clusterID: UInt32 = 0x1F43B675

    static let subtitleTrackType: UInt64 = 0x11

    /// Reads the index of the file behind `source`.
    static func load(from source: SubtitleIndexByteSource) async throws -> MatroskaSubtitleIndex {
        var reader = BudgetedReader(source: source)
        let head = try await reader.read(offset: 0, length: headBytes)
        guard let ebml = EBML.element(in: head.data, at: 0), ebml.id == ebmlID,
              let segment = EBML.element(in: head.data, at: ebml.end), segment.id == segmentID else {
            throw SubtitleIndexError.notMatroska
        }
        let segmentStart = Int64(segment.dataStart)
        let totalSize = head.totalSize

        // Top-level elements already in the head, and the SeekHead's pointers to the rest.
        var positions: [UInt32: Int64] = [:]
        var position = segment.dataStart
        while let element = EBML.element(in: head.data, at: position), element.id != clusterID {
            positions[element.id] = positions[element.id] ?? Int64(element.start)
            guard element.end > position else { break }
            position = element.end
        }
        var seekHeads: [Int64] = positions[seekHeadID].map { [$0] } ?? []
        var visitedSeekHeads = Set<Int64>()
        while let next = seekHeads.first, visitedSeekHeads.count < 4 {
            seekHeads.removeFirst()
            guard visitedSeekHeads.insert(next).inserted,
                  let body = try await reader.element(at: next, expecting: seekHeadID, maxBytes: 1024 * 1024, head: head.data) else { continue }
            for entry in EBML.children(of: body, id: seekID) {
                guard let idBytes = EBML.child(of: entry, id: seekElementID),
                      let target = EBML.child(of: entry, id: seekPositionID) else { continue }
                let id = UInt32(truncatingIfNeeded: EBML.uint(idBytes))
                let absolute = segmentStart + Int64(EBML.uint(target))
                if id == seekHeadID {
                    seekHeads.append(absolute)
                } else if positions[id] == nil {
                    positions[id] = absolute
                }
            }
        }

        var timestampScale: Double = 1_000_000
        if let infoPosition = positions[infoID],
           let info = try await reader.element(at: infoPosition, expecting: infoID, maxBytes: maxInfoBytes, head: head.data),
           let scale = EBML.child(of: info, id: timestampScaleID) {
            let value = EBML.uint(scale)
            if value > 0 { timestampScale = Double(value) }
        }

        guard let tracksPosition = positions[tracksID],
              let tracksBody = try await reader.element(at: tracksPosition, expecting: tracksID, maxBytes: maxTracksBytes, head: head.data) else {
            throw SubtitleIndexError.tracksNotFound
        }
        var tracks = parseTracks(tracksBody)
        guard !tracks.isEmpty else { throw SubtitleIndexError.noSubtitleTracks }

        var foundCues: Data?
        if let cuesPosition = positions[cuesID] {
            foundCues = try await reader.element(at: cuesPosition, expecting: cuesID, maxBytes: maxCuesBytes, head: head.data)
        }
        if foundCues == nil, let totalSize {
            foundCues = try await reader.cuesNearEnd(totalSize: totalSize)
        }
        guard let cuesBody = foundCues else { throw SubtitleIndexError.noIndex }

        let secondsPerTick = timestampScale / 1_000_000_000
        var eventsByTrack: [UInt64: [(start: Double, duration: Double?)]] = [:]
        let wanted = Set(tracks.map(\.number))
        for point in EBML.children(of: cuesBody, id: cuePointID) {
            guard let time = EBML.child(of: point, id: cueTimeID) else { continue }
            let start = Double(EBML.uint(time)) * secondsPerTick
            for positionsElement in EBML.children(of: point, id: cueTrackPositionsID) {
                guard let trackBytes = EBML.child(of: positionsElement, id: cueTrackID) else { continue }
                let track = EBML.uint(trackBytes)
                guard wanted.contains(track) else { continue }
                let duration = EBML.child(of: positionsElement, id: cueDurationID)
                    .map { Double(EBML.uint($0)) * secondsPerTick }
                eventsByTrack[track, default: []].append((start, duration))
            }
        }
        for index in tracks.indices {
            tracks[index].events = (eventsByTrack[tracks[index].number] ?? []).sorted { $0.start < $1.start }
        }
        guard tracks.contains(where: { !$0.events.isEmpty }) else { throw SubtitleIndexError.noIndex }
        return MatroskaSubtitleIndex(tracks: tracks, requests: reader.requests, bytes: reader.bytes)
    }

    static func parseTracks(_ body: Data) -> [MatroskaSubtitleTrack] {
        EBML.children(of: body, id: trackEntryID).compactMap { entry in
            guard let type = EBML.child(of: entry, id: trackTypeID), EBML.uint(type) == subtitleTrackType,
                  let number = EBML.child(of: entry, id: trackNumberID),
                  let codec = EBML.child(of: entry, id: codecIDID) else { return nil }
            func flag(_ id: UInt32, default value: Bool) -> Bool {
                EBML.child(of: entry, id: id).map { EBML.uint($0) != 0 } ?? value
            }
            let language = (EBML.child(of: entry, id: languageBCP47ID) ?? EBML.child(of: entry, id: languageID))
                .map(EBML.string) ?? "eng"
            return MatroskaSubtitleTrack(
                number: EBML.uint(number),
                codecID: EBML.string(codec),
                language: language,
                name: EBML.child(of: entry, id: nameID).map(EBML.string),
                isDefault: flag(flagDefaultID, default: true),
                isForced: flag(flagForcedID, default: false),
                isHearingImpaired: flag(flagHearingImpairedID, default: false),
                isCommentary: flag(flagCommentaryID, default: false),
                events: [])
        }
    }

    /// The range reads of one index load, within the request and byte budget.
    struct BudgetedReader {
        let source: SubtitleIndexByteSource
        private(set) var requests = 0
        private(set) var bytes: Int64 = 0

        init(source: SubtitleIndexByteSource) { self.source = source }

        mutating func read(offset: Int64, length: Int) async throws -> (data: Data, totalSize: Int64?) {
            guard requests < MatroskaSubtitleIndex.maxRequests,
                  bytes + Int64(length) <= MatroskaSubtitleIndex.maxTotalBytes else {
                throw SubtitleIndexError.budgetExceeded
            }
            requests += 1
            let result = try await source.read(offset: offset, length: length)
            bytes += Int64(result.data.count)
            // The parser indexes from zero.
            let data = result.data.startIndex == 0 ? result.data : Data(result.data)
            return (data, result.totalSize)
        }

        /// The body of the element at `position` with `id`, from the head when it is all there.
        mutating func element(at position: Int64, expecting id: UInt32, maxBytes: Int, head: Data) async throws -> Data? {
            if position < Int64(head.count),
               let element = EBML.element(in: head, at: Int(position)), element.id == id,
               element.end <= head.count {
                return head.subdata(in: element.dataStart..<element.end)
            }
            let header = try await read(offset: position, length: 16)
            guard let element = EBML.header(in: header.data, at: 0), element.id == id,
                  let size = element.size, size <= UInt64(maxBytes) else { return nil }
            let body = try await read(offset: position + Int64(element.dataStart), length: Int(size))
            return body.data.count == Int(size) ? body.data : nil
        }

        /// Cues written after the clusters without a SeekHead entry: found by their ID near the end.
        mutating func cuesNearEnd(totalSize: Int64) async throws -> Data? {
            let length = Int(min(Int64(MatroskaSubtitleIndex.tailScanBytes), totalSize))
            let start = totalSize - Int64(length)
            let tail = try await read(offset: start, length: length).data
            let pattern: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
            let bytes = [UInt8](tail)
            var index = bytes.count - pattern.count
            while index >= 0 {
                if bytes[index] == pattern[0], bytes[index + 1] == pattern[1],
                   bytes[index + 2] == pattern[2], bytes[index + 3] == pattern[3],
                   let element = EBML.element(in: tail, at: index), element.end <= tail.count,
                   EBML.element(in: tail, at: element.dataStart)?.id == MatroskaSubtitleIndex.cuePointID {
                    return tail.subdata(in: element.dataStart..<element.end)
                }
                index -= 1
            }
            return nil
        }
    }
}

/// Just enough EBML to walk Matroska's top-level elements and the index.
enum EBML {
    struct Element {
        let id: UInt32
        let start: Int
        let dataStart: Int
        /// Nil for an unknown size (a live Segment or Cluster).
        let size: UInt64?
        /// Where the element ends; the end of the buffer for an unknown size.
        let end: Int
    }

    /// The ID and size at `offset`, without needing the body in `data`.
    static func header(in data: Data, at offset: Int) -> Element? {
        guard let id = vint(in: data, at: offset, keepMarker: true), id.length <= 4,
              let size = vint(in: data, at: offset + id.length, keepMarker: false) else { return nil }
        let dataStart = offset + id.length + size.length
        let unknown = size.value == (UInt64(1) << (7 * UInt64(size.length))) - 1
        // A size past what an Int holds is garbage: it ends at the buffer's end like an unknown one.
        let length = Int(clamping: size.value)
        let end = unknown || length > Int.max - dataStart ? data.count : dataStart + length
        return Element(id: UInt32(truncatingIfNeeded: id.value), start: offset, dataStart: dataStart,
                       size: unknown ? nil : size.value, end: end)
    }

    /// An element whose header is in `data` (its body may run past the end).
    static func element(in data: Data, at offset: Int) -> Element? {
        guard offset >= 0, offset < data.count, let found = EBML.header(in: data, at: offset),
              found.dataStart <= data.count else { return nil }
        return found
    }

    static func vint(in data: Data, at offset: Int, keepMarker: Bool) -> (value: UInt64, length: Int)? {
        guard offset >= 0, offset < data.count else { return nil }
        let base = data.startIndex
        let first = data[base + offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, offset + length <= data.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        for index in 1..<length {
            value = value << 8 | UInt64(data[base + offset + index])
        }
        return (value, length)
    }

    /// The bodies of the children of `parent` with `id`.
    static func children(of parent: Data, id: UInt32) -> [Data] {
        var result: [Data] = []
        var offset = 0
        while let item = EBML.element(in: parent, at: offset), item.size != nil {
            let end = min(item.end, parent.count)
            if item.id == id { result.append(parent.subdata(in: item.dataStart..<end)) }
            guard item.end > offset else { break }
            offset = item.end
        }
        return result
    }

    static func child(of parent: Data, id: UInt32) -> Data? {
        var offset = 0
        while let item = EBML.element(in: parent, at: offset), item.size != nil {
            if item.id == id { return parent.subdata(in: item.dataStart..<min(item.end, parent.count)) }
            guard item.end > offset else { break }
            offset = item.end
        }
        return nil
    }

    static func uint(_ data: Data) -> UInt64 {
        data.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func string(_ data: Data) -> String {
        let trimmed = data.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
