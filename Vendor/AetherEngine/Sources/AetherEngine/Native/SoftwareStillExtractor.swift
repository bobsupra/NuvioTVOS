import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import AetherLibavcodec
import AetherLibavformat

/// Decodes one still out of a run of demuxed packets (#544). No demuxer and no container: the
/// software live path already holds its whole timeshift window as packets, it only ever lacked an
/// image consumer.
///
/// It drives a real `SoftwareVideoDecoder` rather than a minimal one of its own, so the still is the
/// picture the renderer would show. Broadcast is where that matters: interlaced MPEG-2 at a
/// non-square sample aspect is the normal case on a tuner, and both the deinterlace and the SAR
/// resolution behind it are hardened here already. A second decoder would have to re-derive them and
/// would get a combed, stretched frame wrong in exactly the cases the preview exists for.
///
/// Not thread-safe by itself: the host owns one and serialises requests onto its own queue, off the
/// demux and feed loops, so a still never costs playback a packet.
final class SoftwareStillExtractor: @unchecked Sendable {

    /// Bounds on one run. A broadcast GOP is well under a second; these refuse the pathological
    /// stream rather than letting it hold a request.
    struct Limits {
        var maxPackets: Int = 900
        var maxSpanSeconds: Double = 12
        /// Packets are stored in decode order, so the frame at the target can sit behind the first
        /// packet that reaches it. Two B-frames is the common broadcast shape; four covers the rest.
        var reorderTail: Int = 4
    }

    private let decoder = SoftwareVideoDecoder()
    private let videoStreamIndex: Int32
    private let timeBaseSeconds: Double
    private let limits: Limits
    private var isOpen = false

    init(stream: UnsafeMutablePointer<AVStream>,
         videoStreamIndex: Int32,
         timeBaseSeconds: Double,
         deinterlace: DeinterlaceConfig,
         limits: Limits = Limits()) throws {
        self.videoStreamIndex = videoStreamIndex
        self.timeBaseSeconds = timeBaseSeconds
        self.limits = limits
        decoder.deinterlaceConfig = deinterlace
        decoder.decodesSingleThreaded = true
        try decoder.open(stream: stream) { _, _, _ in }
        isOpen = true
    }

    deinit {
        decoder.close()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        decoder.close()
    }

    /// The frame at `targetPts` (source axis), or nil when the ring cannot serve it.
    ///
    /// Every request is an independent landing, so the decoder is flushed first: a still is a seek,
    /// and carrying references across two unrelated positions is what produces a smeared picture.
    func still(from ring: PacketRingBuffer, targetPts: Double, maxWidth: Int) -> CGImage? {
        guard isOpen, timeBaseSeconds > 0, maxWidth > 0 else { return nil }
        guard let run = ring.stillRun(target: targetPts,
                                      maxPackets: limits.maxPackets,
                                      maxSpanSeconds: limits.maxSpanSeconds,
                                      reorderTail: limits.reorderTail),
              !run.isEmpty else { return nil }

        let collector = FrameCollector(target: targetPts)
        decoder.onFrame = { pixelBuffer, pts, _ in
            collector.append(pixelBuffer: pixelBuffer, seconds: pts.seconds)
        }
        decoder.flush()
        defer { decoder.onFrame = nil }

        for packet in run {
            feed(packet)
        }

        guard let best = collector.best else { return nil }
        return Self.image(from: best, maxWidth: maxWidth)
    }

    // MARK: - Feeding

    private func feed(_ packet: PacketRingBuffer.Packet) {
        guard !packet.bytes.isEmpty else { return }
        // Through the tracked pair, so the still path stays visible to PacketBalanceTracker.
        guard let p = trackedPacketAlloc() else { return }
        var pkt: UnsafeMutablePointer<AVPacket>? = p
        defer { trackedPacketFree(&pkt) }

        guard av_new_packet(p, Int32(packet.bytes.count)) >= 0 else { return }
        packet.bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = p.pointee.data {
                memcpy(dst, base, packet.bytes.count)
            }
        }
        p.pointee.pts = Int64((packet.pts / timeBaseSeconds).rounded())
        p.pointee.dts = p.pointee.pts
        p.pointee.flags = packet.isKeyframe ? AV_PKT_FLAG_KEY : 0
        p.pointee.stream_index = videoStreamIndex
        decoder.decode(packet: p, epoch: nil)
    }

    // MARK: - Frame selection

    /// Keeps the best candidate as the run decodes rather than every frame it produced. The buffers
    /// come out of the decoder's own pool, so holding a whole GOP of them would starve the pool the
    /// next run has to draw from. Two are enough: the one the target asks for, and the oldest as the
    /// fallback below.
    ///
    /// `onFrame` is `@Sendable` and the decoder calls it from its own drain, so the box is locked
    /// even though the run itself is serial.
    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let target: Double
        private var atOrBefore: (pixelBuffer: CVPixelBuffer, seconds: Double)?
        private var earliest: (pixelBuffer: CVPixelBuffer, seconds: Double)?

        init(target: Double) {
            self.target = target
        }

        func append(pixelBuffer: CVPixelBuffer, seconds: Double) {
            guard seconds.isFinite else { return }
            lock.lock()
            defer { lock.unlock() }
            if earliest == nil || seconds < earliest!.seconds {
                earliest = (pixelBuffer, seconds)
            }
            guard seconds <= target else { return }
            if atOrBefore == nil || seconds > atOrBefore!.seconds {
                atOrBefore = (pixelBuffer, seconds)
            }
        }

        /// The newest frame at or before the target.
        ///
        /// The fallback is not the live edge: a run opens on a keyframe at or before the target, so
        /// a frame at or before it normally exists. It covers the eviction race, where that opening
        /// keyframe was dropped between the index snapshot and the disk read and the run therefore
        /// begins AFTER the target. Returning the earliest frame there is a picture from up to one
        /// GOP late, which is a better answer than an empty card.
        var best: CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return (atOrBefore ?? earliest)?.pixelBuffer
        }
    }

    // MARK: - Image

    /// The decoder attaches the resolved sample aspect to the buffer (`#177`), so the still reads
    /// its answer rather than resolving one of its own, and a 704x480 4:3 broadcast frame draws 4:3.
    static func image(from pixelBuffer: CVPixelBuffer, maxWidth: Int) -> CGImage? {
        var cgImage: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage) == noErr,
              let source = cgImage else { return nil }

        let srcW = source.width
        let srcH = source.height
        guard srcW > 0, srcH > 0 else { return nil }

        let (dstW, dstH) = FrameDecodeContext.displayDimensions(
            srcW: srcW, srcH: srcH, sar: sampleAspect(of: pixelBuffer), targetWidth: maxWidth)

        // Always drawn into an owned bitmap, even at 1:1. VideoToolbox documents the CGImage as
        // backed by the CVPixelBuffer it was made from, and that buffer goes back to the decoder's
        // pool the moment this run lets go of it, so handing the source out would let the next run
        // repaint a picture the host is still showing.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: dstW, height: dstH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return source
        }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return ctx.makeImage() ?? source
    }

    static func sampleAspect(of pixelBuffer: CVPixelBuffer) -> AVRational {
        guard let attachment = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil) as? [CFString: Any],
            let h = attachment[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int,
            let v = attachment[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int,
            h > 0, v > 0 else {
            return AVRational(num: 1, den: 1)
        }
        return AVRational(num: Int32(h), den: Int32(v))
    }
}
