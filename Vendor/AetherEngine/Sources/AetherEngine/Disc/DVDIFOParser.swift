import Foundation

/// A DVD-Video title from the VMGI Title Search Pointer Table (TT_SRPT). Maps the disc's user-visible
/// titles onto the title sets (VTS) that back them, with each title's chapter count (#67).
struct DVDIFOTitle: Equatable {
    /// 1-based title-set number (VTS_NN_*). The whole-VTS title resolution concatenates this VTS's VOBs.
    let vtsn: Int
    /// Title number within its VTS (vts_ttn). Multiple titles can share a VTS (episodic TV).
    let vtsTitleNumber: Int
    /// Number of parts-of-title (PTTs = chapters) in this title. Surfaced for chapter enumeration (Phase 4).
    let chapterCount: Int
    /// Number of angles (1 for non-multiangle titles).
    let angleCount: Int
}

/// Parses the DVD-Video Video Manager (VIDEO_TS.IFO / VMGI) just far enough to enumerate titles. The
/// VMGI_MAT holds the TT_SRPT start sector at byte offset 0xC4; TT_SRPT lists every title with the VTS
/// that backs it. Byte layout per libdvdread's ifo_types (tt_srpt_t / title_info_t).
enum DVDIFOParser {
    private static let vmgMagic = Array("DVDVIDEO-VMG".utf8)
    private static let sectorSize = 2048
    /// VMGI_MAT offset of the 4-byte TT_SRPT start-sector pointer.
    private static let ttSrptPointerOffset = 0xC4

    /// Returns the disc's titles from TT_SRPT, or nil if the bytes are not a recognizable VMGI / the table
    /// is malformed or out of range (the caller then falls back to the VOB-size heuristic).
    static func parseTitles(_ data: [UInt8]) -> [DVDIFOTitle]? {
        guard data.count >= ttSrptPointerOffset + 4,
              Array(data[0..<12]) == vmgMagic else { return nil }
        let ttSrptSector = be32(data, ttSrptPointerOffset)
        // Sector 0 would overlap the VMGI header; treat as absent.
        guard ttSrptSector > 0 else { return nil }
        let base = ttSrptSector * sectorSize
        // TT_SRPT header: nr_of_titles(2) + reserved(2) + last_byte(4) = 8 bytes, then 12-byte entries.
        guard base + 8 <= data.count else { return nil }
        let nrTitles = be16(data, base)
        guard nrTitles > 0 else { return nil }
        var titles: [DVDIFOTitle] = []
        titles.reserveCapacity(nrTitles)
        for i in 0..<nrTitles {
            let entry = base + 8 + i * 12
            guard entry + 12 <= data.count else { break }
            let angles = Int(data[entry + 1])
            let ptts = be16(data, entry + 2)
            let vtsn = Int(data[entry + 6])
            let ttn = Int(data[entry + 7])
            // A title must name a real (1-based) title set; skip a corrupt zero entry rather than abort.
            guard vtsn > 0 else { continue }
            titles.append(DVDIFOTitle(vtsn: vtsn, vtsTitleNumber: ttn, chapterCount: ptts, angleCount: angles))
        }
        return titles.isEmpty ? nil : titles
    }

    // MARK: - VTS IFO (per-title duration + chapters)

    private static let vtsMagic = Array("DVDVIDEO-VTS".utf8)
    /// VTSI_MAT offset of the 4-byte VTS_PGCIT start-sector pointer.
    private static let vtsPgcitPointerOffset = 0xCC
    /// PGC header field offsets (relative to the PGC start), per libdvdread pgc_t.
    private static let pgcNrProgramsOffset = 0x02
    private static let pgcNrCellsOffset = 0x03
    private static let pgcPlaybackTimeOffset = 0x04
    private static let pgcProgramMapOffsetField = 0xE6
    private static let pgcCellPlaybackOffsetField = 0xE8
    /// PGC header length (through cell_position_offset); a PGC must have at least this many bytes.
    private static let pgcHeaderLength = 0xEC
    private static let cellPlaybackEntrySize = 24

    /// Parses a VTS IFO (VTS_NN_0.IFO) for the title's duration and chapter start times. Uses the longest
    /// program chain in the title set (the main feature) and resolves chapters from its program map +
    /// cumulative cell playback times. Returns nil if the bytes are not a recognizable VTSI or the PGCIT is
    /// malformed (the caller then leaves the title's duration at 0 with no chapters).
    static func parseTitleDetail(_ data: [UInt8]) -> (durationTicks: UInt64, chapterStartTicks: [UInt64])? {
        guard data.count >= vtsPgcitPointerOffset + 4,
              Array(data[0..<12]) == vtsMagic else { return nil }
        let pgcitSector = be32(data, vtsPgcitPointerOffset)
        guard pgcitSector > 0 else { return nil }
        let pgcitBase = pgcitSector * sectorSize
        guard pgcitBase + 8 <= data.count else { return nil }
        let nrSrp = be16(data, pgcitBase)
        guard nrSrp > 0 else { return nil }

        // Pick the longest PGC across the table's search pointers (the main feature of a multi-PGC VTS).
        var bestOffset = -1
        var bestTicks: UInt64 = 0
        for i in 0..<nrSrp {
            let srp = pgcitBase + 8 + i * 8
            guard srp + 8 <= data.count else { break }
            let pgcOffset = pgcitBase + be32(data, srp + 4)
            guard pgcOffset >= 0, pgcOffset + pgcHeaderLength <= data.count else { continue }
            let ticks = dvdTimeTicks(data, pgcOffset + pgcPlaybackTimeOffset)
            if bestOffset < 0 || ticks > bestTicks { bestOffset = pgcOffset; bestTicks = ticks }
        }
        guard bestOffset >= 0 else { return nil }
        let chapters = parsePGCChapters(data, pgcOffset: bestOffset)
        return (durationTicks: bestTicks, chapterStartTicks: chapters)
    }

    /// Title-relative chapter starts from a PGC's program map + cumulative cell playback times. A chapter
    /// (program) begins at its entry cell, whose start is the sum of the durations of all preceding cells.
    private static func parsePGCChapters(_ data: [UInt8], pgcOffset: Int) -> [UInt64] {
        let nrPrograms = Int(data[pgcOffset + pgcNrProgramsOffset])
        let nrCells = Int(data[pgcOffset + pgcNrCellsOffset])
        guard nrPrograms > 0, nrCells > 0 else { return [] }
        let programMap = pgcOffset + be16(data, pgcOffset + pgcProgramMapOffsetField)
        let cellTable = pgcOffset + be16(data, pgcOffset + pgcCellPlaybackOffsetField)
        guard programMap + nrPrograms <= data.count,
              cellTable + nrCells * cellPlaybackEntrySize <= data.count else { return [] }
        // Cumulative start (seconds) before each cell; index c is the start of the (1-based) cell c+1.
        var cellStartSeconds = [Double](repeating: 0, count: nrCells + 1)
        for c in 0..<nrCells {
            let dur = dvdTimeSeconds(data, cellTable + c * cellPlaybackEntrySize + pgcPlaybackTimeOffset)
            cellStartSeconds[c + 1] = cellStartSeconds[c] + dur
        }
        var starts: [UInt64] = []
        for p in 0..<nrPrograms {
            let entryCell = Int(data[programMap + p])   // 1-based cell number
            guard entryCell >= 1, entryCell <= nrCells else { continue }
            starts.append(UInt64((cellStartSeconds[entryCell - 1] * discTickRate).rounded()))
        }
        var seen = Set<UInt64>()
        return starts.sorted().filter { seen.insert($0).inserted }
    }

    /// dvd_time_t (4 bytes) -> seconds. BCD hour/minute/second; the frame byte's top 2 bits select the
    /// frame rate (1 = 25 fps, 3 = 30000/1001), its low 6 bits are the BCD frame count.
    private static func dvdTimeSeconds(_ b: [UInt8], _ i: Int) -> Double {
        func bcd(_ x: UInt8) -> Int { Int(x >> 4) * 10 + Int(x & 0x0F) }
        let h = bcd(b[i]); let m = bcd(b[i + 1]); let s = bcd(b[i + 2])
        let frameByte = b[i + 3]
        let fpsCode = (Int(frameByte) & 0xC0) >> 6
        let fps: Double = fpsCode == 1 ? 25.0 : (fpsCode == 3 ? 30000.0 / 1001.0 : 0)
        let frames = bcd(frameByte & 0x3F)
        return Double(h * 3600 + m * 60 + s) + (fps > 0 ? Double(frames) / fps : 0)
    }
    private static func dvdTimeTicks(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64((dvdTimeSeconds(b, i) * discTickRate).rounded())
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i+1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
    }
}
