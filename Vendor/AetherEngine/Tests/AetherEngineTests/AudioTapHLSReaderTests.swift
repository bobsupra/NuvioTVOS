import XCTest
import AVFAudio
@testable import AetherEngine

final class AudioTapHLSReaderTests: XCTestCase {
    /// Reference box so the `@Sendable` dep closures can mutate test-captured state.
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    // A mono 48k WAV per segment so decodeSegment yields real chunks.
    private func wav(seconds: Double) -> Data {
        let sr = 48_000, frames = Int(Double(sr) * seconds)
        var pcm = Data(capacity: frames * 2)
        for n in 0..<frames {
            let v = Int16(9000 * sin(2 * .pi * 440 * Double(n) / Double(sr)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var d = Data(); func s(_ x: String){ d.append(x.data(using:.ascii)!) }
        func u32(_ v: UInt32){ withUnsafeBytes(of: v.littleEndian){ d.append(contentsOf:$0) } }
        func u16(_ v: UInt16){ withUnsafeBytes(of: v.littleEndian){ d.append(contentsOf:$0) } }
        s("RIFF"); u32(UInt32(36+pcm.count)); s("WAVE"); s("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sr)); u32(UInt32(sr*2)); u16(2); u16(16); s("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    private func vodPlaylist() -> HLSMediaPlaylist {
        HLSMediaPlaylist(targetDuration: 6, mediaSequence: 0,
            segments: (0..<4).map { HLSMediaSegment(uri: "s\($0).ts", duration: 6, discontinuityBefore: false) },
            hasEndList: true, isEncrypted: false, hasUnsupportedEncryption: false, hasMap: false)
    }

    func testVODStepDecodesSegmentContainingPlayhead() async {
        let playhead = 13.0                       // inside segment index 2 (12..18)
        let fetchedIdx = Box<[Int]>([])
        let emitted = Box<[AudioTapBuffer]>([])
        let pl = vodPlaylist()
        let seg = wav(seconds: 6)
        let deps = AudioTapHLSReader.Dependencies(
            playhead: { playhead },
            mediaURL: URL(string: "https://h/media.m3u8")!,
            fetchPlaylist: { _ in pl },
            fetchSegment: { uri, _ in
                let idx = Int(uri.dropFirst(1).prefix(1)) ?? -1     // "s2.ts" -> 2
                fetchedIdx.value.append(idx); return seg
            },
            decodeSegment: { AudioTapSegmentDecoder().decode(selfContainedSegment: $0) },
            emit: { emitted.value.append($0) })
        let reader = AudioTapHLSReader(deps: deps)
        reader.primeForTest(playlist: pl)          // sets VOD mode + durations without network
        _ = await reader.stepVOD()
        XCTAssertEqual(fetchedIdx.value.first, 2)                       // fetched the playhead's segment
        XCTAssertTrue(emitted.value.first?.discontinuity ?? false)     // first buffer after anchor
        XCTAssertEqual(emitted.value.first?.sourceTime ?? -1, 12.0, accuracy: 0.05) // seg 2 start
    }

    func testVODReanchorsOnPlayheadJump() async {
        let playhead = Box<Double>(1.0)
        let emitted = Box<[AudioTapBuffer]>([])
        let pl = vodPlaylist()
        let seg = wav(seconds: 6)
        let deps = AudioTapHLSReader.Dependencies(
            playhead: { playhead.value },
            mediaURL: URL(string: "https://h/media.m3u8")!,
            fetchPlaylist: { _ in pl },
            fetchSegment: { _, _ in seg },
            decodeSegment: { AudioTapSegmentDecoder().decode(selfContainedSegment: $0) },
            emit: { emitted.value.append($0) })
        let reader = AudioTapHLSReader(deps: deps)
        reader.primeForTest(playlist: pl)
        _ = await reader.stepVOD()                 // decodes seg 0 at t=0, discontinuity=true
        playhead.value = 19.0                       // jump into seg 3
        let reanchor = await reader.stepVOD()       // pacing sees divergence -> reanchor
        XCTAssertEqual(reanchor, .reanchored)
        _ = await reader.stepVOD()                  // decodes seg 3 at t=18, discontinuity=true again
        let seg3 = emitted.value.filter { $0.sourceTime >= 18.0 }
        XCTAssertFalse(seg3.isEmpty)                // seg 3 audio present
        XCTAssertTrue(seg3.first?.discontinuity ?? false) // first buffer after reanchor flagged
    }
}
