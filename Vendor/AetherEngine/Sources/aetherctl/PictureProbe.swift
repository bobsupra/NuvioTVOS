import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// AE#418: which SOURCE frame is AVPlayer presenting at a given item time?
///
/// Every axis observable the engine has describes what it WROTE: `MuxedVideoFrameTime` (#260) pairs
/// the demuxed PTS with the value muxed into the segment, `prodShift` / `hostShift` describe the fold
/// the clock applies. None of them says where AVPlayer then PUT that segment, and a plan boundary the
/// producer had to open below is exactly the case where the two can disagree. AE#408 shipped on the
/// assumption that they cannot, which is what this reads out instead of assuming.
///
/// The fixture states its own frame number in the picture (12 white blocks, bit k of the frame index,
/// `Scripts/timecode-fixture.sh`), so one pixel row decodes to a source time with no OCR and no
/// tolerance to argue about. `itemTimeForDisplay` is AVPlayer's own label for the frame it handed
/// over, so the pair is measured at one instant on both axes.
final class PictureProbe: @unchecked Sendable {
    struct Sample {
        /// AVPlayer's item time for the frame it just handed over.
        let itemTime: Double
        /// Source time decoded from that frame's own picture.
        let pictureSourceTime: Double
        /// What the picture is worth minus where AVPlayer says it sits. 0 on an honest axis.
        var axisError: Double { pictureSourceTime - itemTime }
    }

    private let blocks: Int
    private let blockPitch: Int
    private let blockCenter: Int
    private let frameRate: Double
    private var output: AVPlayerItemVideoOutput?
    private var attachedItem: AVPlayerItem?
    private(set) var attachCount = 0

    init(blocks: Int = 12, blockPitch: Int = 52, blockCenter: Int = 25, frameRate: Double = 24) {
        self.blocks = blocks
        self.blockPitch = blockPitch
        self.blockCenter = blockCenter
        self.frameRate = frameRate
    }

    /// The item is swapped in place on a reload, and an output belongs to one item, so re-attach on
    /// identity rather than once.
    @MainActor
    func attachIfNeeded(_ item: AVPlayerItem?) {
        guard let item, item !== attachedItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        self.output = output
        self.attachedItem = item
        attachCount += 1
    }

    /// nil when the output has no new frame for this instant, which is a normal read on a stalled or
    /// pre-roll session and must not be reported as a zero.
    func sample() -> Sample? {
        guard let output else { return nil }
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard itemTime.isNumeric else { return nil }
        var display = CMTime.zero
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &display),
              let frameIndex = Self.decodeFrameIndex(
                  from: buffer, blocks: blocks, pitch: blockPitch, center: blockCenter)
        else { return nil }
        return Sample(
            itemTime: display.isNumeric ? display.seconds : itemTime.seconds,
            pictureSourceTime: Double(frameIndex) / frameRate)
    }

    /// The picture carries the frame index as `blocks` white/black cells on one row. A cell is read at
    /// its centre, so encoder ringing at the edges cannot flip a bit.
    static func decodeFrameIndex(
        from buffer: CVPixelBuffer, blocks: Int, pitch: Int, center: Int
    ) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard height > center, width > (blocks - 1) * pitch + center else { return nil }
        let row = base.advanced(by: center * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        var index = 0
        for bit in 0..<blocks {
            // BGRA: green is the middle byte and carries the full-resolution luma difference here.
            let green = row[(bit * pitch + center) * 4 + 1]
            if green > 128 { index |= (1 << bit) }
        }
        return index
    }
}
