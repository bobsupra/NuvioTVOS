import Foundation
import AetherEngine

// MARK: - disc-inspect

/// Walk a local disc image at the filesystem layer and report what DiscReader makes
/// of it. FFmpeg-free: answers "is this a recognizable DVD/Blu-ray, and if not, where
/// does detection bail?". Exit 0 when the image is recognized as playable, else 1.
func runDiscInspect(url: URL, dump: Bool = false) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl disc-inspect: \(url.absoluteString)")
    print("")

    let d = AetherEngine.inspectDisc(url: url, verbose: dump)

    func bytesLabel(_ b: Int64) -> String {
        guard b > 0 else { return "0" }
        return String(format: "%lld bytes (%.2f GB)", b, Double(b) / 1_073_741_824.0)
    }

    print("Verdict:     \(d.kind.rawValue)")
    print("Signatures:  ISO9660=\(d.iso9660Signature)  UDF-anchor=\(d.udfAnchor)")
    if let err = d.udfParseError {
        print("UDF error:   \(err)")
    }
    print("")

    if !d.dvdVOBFiles.isEmpty {
        print("VIDEO_TS:    \(d.dvdVOBFiles.count) entries")
        for name in d.dvdVOBFiles.prefix(40) { print("  \(name)") }
        print("")
    }

    if d.udfAnchor {
        print("UDF root:    \(d.rootEntries.isEmpty ? "(empty / unreadable)" : "")")
        for e in d.rootEntries.prefix(40) { print("  \(e)") }
        print("BDMV:        \(d.bdmvPresent ? "present" : "MISSING")")
        print("")

        if d.bdmvPresent {
            print("PLAYLIST:    \(d.playlistFiles.count) entries, \(d.parsedPlaylists.count) parsed")
            for pl in d.parsedPlaylists.prefix(40) {
                print(String(format: "  %@  clips=%d  dur=%.1fs", pl.name, pl.clipCount, pl.durationSeconds))
            }
            if !d.selectedTitleClipIDs.isEmpty {
                print("Main title:  clips=\(d.selectedTitleClipIDs)")
            }
            print("STREAM:      \(d.streamFiles.count) entries")
            for name in d.streamFiles.prefix(40) { print("  \(name)") }
            print("m2ts extents resolved: \(d.resolvedM2TSExtentCount)  total=\(bytesLabel(d.resolvedM2TSBytes))")
            print("")
        }
    }

    print("DiscReader.wrap: \(d.wrapRecognized ? "RECOGNIZED (format hint: \(d.wrapFormatHint ?? "?"))" : "nil (NOT recognized -> falls back to raw FFmpeg open)")")

    func hms(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
    if !d.titles.isEmpty {
        print("")
        print("Titles:      \(d.titles.count) (selected: \(d.selectedTitleIndex))")
        for t in d.titles {
            let dur = t.durationSeconds > 0 ? hms(t.durationSeconds) : "unknown"
            print("  [\(t.id)] dur=\(dur)  chapters=\(t.chapterStartsSeconds.count)")
            if !t.chapterStartsSeconds.isEmpty {
                let shown = t.chapterStartsSeconds.prefix(40).map { hms($0) }.joined(separator: ", ")
                let more = t.chapterStartsSeconds.count > 40 ? ", ..." : ""
                print("        @ \(shown)\(more)")
            }
        }
    }
    return d.wrapRecognized ? 0 : 1
}
