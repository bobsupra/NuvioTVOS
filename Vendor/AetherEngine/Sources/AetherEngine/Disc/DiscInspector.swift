import Foundation

/// Structured result of walking a local disc image (DVD-Video or Blu-ray) at the
/// filesystem layer, without FFmpeg. Mirrors the decisions `DiscReader.wrap` makes
/// but records every stage, so a failed recognition is debuggable instead of a
/// silent `nil` that downstream surfaces as a bare FFmpeg `INVALIDDATA`.
///
/// Diagnostic only. Playback always goes through `DiscReader.wrap`; `wrapRecognized`
/// reports what that path would decide for the same image.
public struct DiscInspection: Sendable {
    public enum Kind: String, Sendable {
        case notADisc          // no ISO9660 signature and no UDF anchor
        case dvdVideo          // ISO9660 + VIDEO_TS with a selectable title
        case bluRay            // UDF + BDMV with a selectable title and resolved m2ts extents
        case iso9660NoTitle    // ISO9660 present but no playable DVD-Video title
        case udfNoBDMV         // UDF present but no BDMV directory in the root
        case udfNoTitle        // BDMV present but no parseable playlist / no resolved m2ts extents
        case udfParseFailed    // UDF anchor present but volume structure unreadable
    }

    public struct PlaylistSummary: Sendable {
        public let name: String
        public let clipCount: Int
        public let durationSeconds: Double
    }

    /// A selectable title as `DiscReader.wrap` enumerates it, with its chapter start offsets (#67).
    public struct TitleSummary: Sendable {
        public let id: Int
        public let durationSeconds: Double
        public let chapterStartsSeconds: [Double]
    }

    public var kind: Kind = .notADisc
    public var iso9660Signature: Bool = false
    public var udfAnchor: Bool = false
    public var udfParseError: String?
    public var rootEntries: [String] = []
    public var bdmvPresent: Bool = false
    public var playlistFiles: [String] = []
    public var parsedPlaylists: [PlaylistSummary] = []
    public var selectedTitleClipIDs: [String] = []
    public var streamFiles: [String] = []
    public var resolvedM2TSExtentCount: Int = 0
    public var resolvedM2TSBytes: Int64 = 0
    public var dvdVOBFiles: [String] = []
    /// What `DiscReader.wrap` would return for this image (non-nil = recognized as playable).
    public var wrapRecognized: Bool = false
    public var wrapFormatHint: String?
    /// The full selectable-title list (with chapters) the engine would expose, longest first (#67).
    public var titles: [TitleSummary] = []
    public var selectedTitleIndex: Int = 0
}

/// Diagnostic mirror of `DiscReader.wrap`. Walks the disc filesystem verbosely and
/// records intermediate state. Used by `aetherctl disc-inspect` and unit tests.
enum DiscInspector {
    /// Blu-ray playlist ticks run at 45 kHz (90 kHz / 2).
    private static let bdTickRate: Double = 45000.0

    static func inspect(_ reader: IOReader) -> DiscInspection {
        var d = DiscInspection()
        d.iso9660Signature = DiscReader.looksLikeISO9660(reader)
        d.udfAnchor = DiscReader.looksLikeUDF(reader)

        var kind: DiscInspection.Kind? = nil

        // DVD-Video (ISO9660 + VIDEO_TS), mirroring DiscReader.wrap's first branch.
        if d.iso9660Signature,
           let iso = try? ISO9660Reader(reader: reader),
           let vts = try? iso.list(directory: "VIDEO_TS") {
            d.dvdVOBFiles = vts.map(\.name)
            if !DVDTitleSelector.selectMainTitleVOBs(vts).isEmpty {
                kind = .dvdVideo
            }
        }

        // Blu-ray (UDF + BDMV).
        if kind == nil, d.udfAnchor {
            do {
                let udf = try UDFReader(reader: reader)
                let root = (try? udf.list(path: [])) ?? []
                d.rootEntries = root.map { ($0.isDir ? "[D] " : "[F] ") + $0.name }
                d.bdmvPresent = root.contains { $0.isDir && $0.name == "BDMV" }
                if d.bdmvPresent {
                    let plDir = (try? udf.list(path: ["BDMV", "PLAYLIST"])) ?? []
                    d.playlistFiles = plDir.map(\.name)
                    var parsed: [MPLSPlaylist] = []
                    for e in plDir where e.name.hasSuffix(".mpls") {
                        guard let exts = try? udf.extents(of: e), !exts.isEmpty else { continue }
                        let bytes = DiscReader.readAll(reader, exts)
                        guard let pl = MPLSParser.parse(bytes) else { continue }
                        parsed.append(pl)
                        d.parsedPlaylists.append(.init(
                            name: e.name,
                            clipCount: pl.clipIDs.count,
                            durationSeconds: Double(pl.durationTicks) / bdTickRate
                        ))
                    }
                    if let title = BDTitleSelector.selectMainTitle(parsed) {
                        d.selectedTitleClipIDs = title.clipIDs
                        let streamDir = (try? udf.list(path: ["BDMV", "STREAM"])) ?? []
                        d.streamFiles = streamDir.map(\.name)
                        var count = 0
                        var bytes: Int64 = 0
                        for clip in title.clipIDs {
                            guard let e = streamDir.first(where: { $0.name == "\(clip).m2ts" }),
                                  let exts = try? udf.extents(of: e) else { continue }
                            count += exts.count
                            bytes += exts.reduce(Int64(0)) { $0 + max(0, $1.length) }
                        }
                        d.resolvedM2TSExtentCount = count
                        d.resolvedM2TSBytes = bytes
                        kind = count > 0 ? .bluRay : .udfNoTitle
                    } else {
                        kind = .udfNoTitle
                    }
                } else {
                    kind = .udfNoBDMV
                }
            } catch {
                d.udfParseError = "\(error)"
                kind = .udfParseFailed
            }
        }

        // Resolve a verdict when neither branch committed.
        d.kind = kind ?? {
            if d.iso9660Signature { return .iso9660NoTitle }
            if d.udfAnchor { return .udfNoBDMV }
            return .notADisc
        }()

        // What the real playback path decides for the same image, plus the full title + chapter list it exposes.
        if let discInfo = (try? DiscReader.wrap(reader)) ?? nil {
            d.wrapRecognized = true
            d.wrapFormatHint = discInfo.formatHint
            d.selectedTitleIndex = discInfo.selectedTitleIndex
            d.titles = discInfo.titles.map { t in
                DiscInspection.TitleSummary(
                    id: t.id,
                    durationSeconds: Double(t.durationTicks) / bdTickRate,
                    chapterStartsSeconds: t.chapters.map { Double($0.startTicks) / bdTickRate }
                )
            }
        }
        return d
    }
}

public extension AetherEngine {
    /// Inspect a local disc image (`.iso` / disc folder mount) at the filesystem layer
    /// and report what the engine's `DiscReader` makes of it. Pure, nonisolated, and
    /// FFmpeg-free: it answers "is this a recognizable DVD/Blu-ray, and if not, where
    /// does detection bail?" for triage. Returns `.notADisc` when the URL is not a
    /// readable local file. `verbose` dumps the UDF volume structure (partition maps,
    /// resolved sectors, file-entry allocation descriptors) under the `.demux` log.
    nonisolated static func inspectDisc(url: URL, verbose: Bool = false) -> DiscInspection {
        guard let reader = FileIOReader(url: url) else { return DiscInspection() }
        defer { reader.close() }
        UDFReader.diagnostics = verbose
        defer { UDFReader.diagnostics = false }
        return DiscInspector.inspect(reader)
    }
}
