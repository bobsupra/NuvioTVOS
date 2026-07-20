import Foundation

/// Groups DVD-Video content VOBs into per-title-set (VTS) titles without needing IFO parsing.
/// VTS_nn_0.VOB = menus; VTS_nn_1..9.VOB = content. Titles are ordered largest-first (total content
/// VOB size, a proxy for duration) so id 0 is the main feature, matching the Blu-ray convention.
enum DVDTitleSelector {
    /// One selectable title = one VTS's content VOBs (whole-VTS resolution; per-cell/episodic splitting
    /// is deferred). VOBs within a title are ordered by part; titles are ordered by total size, largest first.
    static func enumerateTitleVOBGroups(_ files: [DiscFile]) -> [(vtsn: Int, vobs: [DiscFile])] {
        struct Part { let title: Int; let part: Int; let file: DiscFile }
        var parts: [Part] = []
        for f in files {
            guard let (title, part) = parseVOBName(f.name), part >= 1 else { continue }
            parts.append(Part(title: title, part: part, file: f))
        }
        let byTitle = Dictionary(grouping: parts, by: \.title)
        return byTitle
            .map { vtsn, ps in (vtsn: vtsn, vobs: ps.sorted { $0.part < $1.part }.map(\.file)) }
            .sorted { a, b in
                let sa = a.vobs.reduce(0) { $0 + $1.length }
                let sb = b.vobs.reduce(0) { $0 + $1.length }
                // Tie-break on VTS number so the order is deterministic for equal-size groups.
                return sa != sb ? sa > sb : a.vtsn < b.vtsn
            }
    }

    static func selectMainTitleVOBs(_ files: [DiscFile]) -> [DiscFile] {
        enumerateTitleVOBGroups(files).first?.vobs ?? []
    }

    /// Parse "VTS_NN_P.VOB" -> (title NN, part P). Case-insensitive.
    static func parseVOBName(_ name: String) -> (title: Int, part: Int)? {
        let upper = name.uppercased()
        guard upper.hasPrefix("VTS_"), upper.hasSuffix(".VOB") else { return nil }
        let stem = upper.dropFirst(4).dropLast(4)        // "NN_P"
        let comps = stem.split(separator: "_")
        guard comps.count == 2, let t = Int(comps[0]), let p = Int(comps[1]) else { return nil }
        return (t, p)
    }
}
