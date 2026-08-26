import AetherLibavutil

/// Whether a declared sample aspect ratio deserves to be believed. Two gates that catch different
/// lies; both are cheap enough to run per frame.
///
/// #177 (components): live TS has been seen carrying 1088:1 on the codec context. No legitimate
/// pixel aspect ratio needs a component above 256.
///
/// #290 (display aspect): a wrong SAR does not have to be a large one. A live 1080p H.264 channel
/// declaring 3:1, and 2:1 on a later run, passes the component gate and smears 1920x1080 into a
/// 5.33:1 or 3.56:1 band. The magnitude is not the defect, the aspect it produces is, and that
/// cannot be judged without the frame the SAR applies to: 2:1 is a standard VUI value (H.264
/// Table E-1, `ff_h2645_pixel_aspect` idc 16) and exactly right on a 960x1080 broadcast frame,
/// where it resolves to 16:9. The same table carries 32:11 (idc 8), a ratio of 2.909 that is
/// correct on 352x576 half-D1 SD. A bound on the ratio itself therefore cannot separate the two:
/// it would reject real broadcast SD while still admitting the 2:1 that started this.
///
/// A rejected SAR falls back to square pixels. For a stream lying about its SAR that is the right
/// picture; a stream telling the truth never reaches the bound.
enum PixelAspectPolicy {

    /// No real display aspect is wider than 3:1 or narrower than 1:3. Ultra Panavision 70, the
    /// widest format ever shot, is 2.76, and anamorphic SD resolves to 16:9 by construction.
    /// Wider pictures do exist (32:9 desktop captures, signage walls), but they store square
    /// pixels and so never ask this question: only a non-square SAR is ever attached.
    static let maxDisplayAspect: Double = 3.0
    static let minDisplayAspect: Double = 1.0 / 3.0

    /// #177 component gate. Prefer `saneSAR(_:width:height:)` wherever the frame is known; this
    /// overload can only judge the numbers, not what they do.
    static func saneSAR(_ sar: AVRational) -> AVRational? {
        guard sar.num > 0, sar.den > 0, sar.num <= 256, sar.den <= 256 else { return nil }
        return sar
    }

    /// #290: the component gate plus the display aspect this SAR produces on this frame.
    /// Non-positive dimensions fall back to the component gate alone: a frame that cannot state
    /// its own size is not evidence against the SAR.
    static func saneSAR(_ sar: AVRational, width: Int32, height: Int32) -> AVRational? {
        guard let sar = saneSAR(sar) else { return nil }
        // Square pixels correct nothing, so there is no claim to disbelieve: whatever aspect the
        // frame has is the content's, not the SAR's. A 32:9 capture must not be rejected for being
        // wide when it never asked for a correction in the first place.
        guard sar.num != sar.den else { return sar }
        guard width > 0, height > 0 else { return sar }
        let aspect = displayAspect(sar: sar, width: width, height: height)
        guard aspect >= minDisplayAspect, aspect <= maxDisplayAspect else { return nil }
        return sar
    }

    /// Display aspect the coded frame resolves to once the SAR is applied.
    static func displayAspect(sar: AVRational, width: Int32, height: Int32) -> Double {
        (Double(width) * Double(sar.num)) / (Double(height) * Double(sar.den))
    }

    /// The ratio a stream actually deserves, or nil when there is nothing to correct. Bitstream
    /// first, container second (`declaredStreamSAR`), then both gates above. Square pixels return
    /// nil rather than 1:1, because a correction of one is a correction a consumer cannot tell from
    /// a real one.
    ///
    /// This is the single answer every consumer of a source SAR is meant to take: the VT decoder
    /// (#354), the fMP4 the loopback serves, and the ratio the engine publishes to its host. Two of
    /// them resolving it separately is two shapes that can disagree about one picture.
    static func declaredPixelAspect(
        bitstream: AVRational, container: AVRational, width: Int32, height: Int32
    ) -> AVRational? {
        let declared = SoftwareVideoDecoder.declaredStreamSAR(bitstream: bitstream, container: container)
        guard let sane = saneSAR(declared, width: width, height: height),
              sane.num != sane.den else { return nil }
        return sane
    }
}
