import Testing
@testable import AetherEngine

// #77: in-house CEA-608 (line-21) decoder, field-1 / CC1. These cover the decode behaviour the
// extractor feeds it: parity handling, doubled-control suppression, pop-on display/erase, and roll-up.
@Suite("CEA608Decoder field-1 decoding")
struct CEA608DecoderTests {

    /// Odd-parity-encode a 7-bit value so tests feed realistic line-21 bytes (bit 7 = odd parity).
    private func parity(_ v: UInt8) -> UInt8 {
        var bits = 0
        for i in 0..<7 where (v & (1 << i)) != 0 { bits += 1 }
        return (bits % 2 == 0) ? (v | 0x80) : v
    }

    /// Feed a control pair twice (as real 608 does) and collect the actions.
    @discardableResult
    private func doubledControl(_ d: CEA608Decoder, _ b0: UInt8, _ b1: UInt8) -> [CEA608Decoder.Action] {
        var out = d.feed(parity(b0), parity(b1))
        out += d.feed(parity(b0), parity(b1))   // duplicate, must be suppressed
        return out
    }

    private func text(_ d: CEA608Decoder, _ s: String) -> [CEA608Decoder.Action] {
        var out: [CEA608Decoder.Action] = []
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let b1: UInt8 = (i + 1 < bytes.count) ? bytes[i + 1] : 0
            out += d.feed(parity(b0), parity(b1 == 0 ? 0 : b1))
            i += 2
        }
        return out
    }

    @Test("Pop-on caption shows on EOC and clears on EDM")
    func popOnDisplayAndErase() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20)   // RCL: pop-on
        doubledControl(d, 0x14, 0x2E)   // ENM: erase hidden
        doubledControl(d, 0x11, 0x40)   // PAC row 1, col 0, addresses the hidden buffer
        _ = text(d, "HI")               // writes to hidden buffer; not yet displayed
        let onEOC = doubledControl(d, 0x14, 0x2F)   // EOC: flip to display
        #expect(onEOC.contains(.display("HI")))

        let onEDM = doubledControl(d, 0x14, 0x2C)   // EDM: erase displayed
        #expect(onEDM.contains(.clear))
    }

    @Test("Doubled control codes are not processed twice")
    func doubledControlSuppressed() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20)
        doubledControl(d, 0x11, 0x40)
        _ = text(d, "AB")
        // One EOC pair sent twice must flip memory exactly once -> exactly one display action total.
        let actions = doubledControl(d, 0x14, 0x2F)
        #expect(actions == [.display("AB")])
    }

    @Test("Parity bit is stripped before decoding characters")
    func parityStripped() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20)
        doubledControl(d, 0x11, 0x40)
        _ = text(d, "Ok")
        let actions = doubledControl(d, 0x14, 0x2F)
        #expect(actions.contains(.display("Ok")))
    }

    @Test("Roll-up emits the typed line on carriage return, not per character")
    func rollUpCarriageReturn() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x26)   // RU3: roll-up 3 rows
        doubledControl(d, 0x14, 0x40)   // PAC → base row 13 (bottom area, room to roll up)
        // Characters typed into the roll-up base row must NOT emit a cue each (that was cue-spam);
        // FFmpeg emits per completed line, so the line surfaces on CR.
        let whileTyping = text(d, "LINE")
        #expect(whileTyping.isEmpty)
        let onCR = doubledControl(d, 0x14, 0x2D)   // CR → roll + emit
        #expect(onCR.contains(.display("LINE")))
    }

    @Test("Special character decodes (music note)")
    func specialCharacter() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20)
        doubledControl(d, 0x11, 0x40)
        // 0x11 + 0x37 -> special char index 7 == music note.
        doubledControl(d, 0x11, 0x37)
        let actions = doubledControl(d, 0x14, 0x2F)
        #expect(actions.contains(.display("♪")))
    }

    @Test("reset() clears state so a new caption doesn't inherit the old")
    func resetClearsState() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20); doubledControl(d, 0x11, 0x40)
        _ = text(d, "OLD")
        _ = doubledControl(d, 0x14, 0x2F)   // display OLD
        d.reset()
        doubledControl(d, 0x14, 0x20); doubledControl(d, 0x11, 0x40)
        _ = text(d, "NEW")
        let actions = doubledControl(d, 0x14, 0x2F)
        #expect(actions.contains(.display("NEW")))
        #expect(!actions.contains(.display("OLD")))
    }

    @Test("A parity-corrupt high byte drops the whole pair (FFmpeg validate_cc_data_pair)")
    func parityRejectsBadHighByte() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20); doubledControl(d, 0x11, 0x40)
        _ = text(d, "OK")
        // 0x41 has EVEN parity → invalid high byte → the pair (which would otherwise type "AB") is dropped.
        _ = d.feed(0x41, parity(0x42))
        _ = d.feed(0x41, parity(0x42))
        let actions = doubledControl(d, 0x14, 0x2F)
        #expect(actions.contains(.display("OK")))     // not "OKAB"
    }

    @Test("A control sent three times is still processed only once")
    func tripledControlSuppressed() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20); doubledControl(d, 0x11, 0x40)
        _ = text(d, "XY")
        var actions = d.feed(parity(0x14), parity(0x2F))   // EOC #1 → display
        actions += d.feed(parity(0x14), parity(0x2F))      // EOC #2 → suppressed
        actions += d.feed(parity(0x14), parity(0x2F))      // EOC #3 → still suppressed (no self-clear)
        #expect(actions == [.display("XY")])
    }

    @Test("Extended Spanish/French 0x2A decodes to hyphen-minus (FFmpeg glyph table)")
    func extendedGlyphFix() {
        let d = CEA608Decoder()
        doubledControl(d, 0x14, 0x20); doubledControl(d, 0x11, 0x40)
        _ = text(d, "A")                 // extended char replaces the preceding standard char
        doubledControl(d, 0x12, 0x2A)    // FrSp 0x2A → "-" (was wrongly the box-drawing "─")
        let actions = doubledControl(d, 0x14, 0x2F)
        #expect(actions.contains(.display("-")))
    }
}
