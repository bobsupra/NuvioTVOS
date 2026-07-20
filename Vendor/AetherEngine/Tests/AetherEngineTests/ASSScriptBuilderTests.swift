import Testing
@testable import AetherEngine

@Suite("ASSScriptBuilder")
struct ASSScriptBuilderTests {
    let header = """
    [Script Info]
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize
    Style: Default,Open Sans,48

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    @Test("Builds a script with synthesized Dialogue timestamps")
    func basicSynthesis() {
        let b = ASSScriptBuilder(header: header)
        let added = b.add(rawEventText: "5,0,Default,,0,0,0,,Hello {\\i1}there{\\i0}", start: 61.5, end: 63.875)
        #expect(added)
        let script = b.script()
        #expect(script.hasPrefix(header))
        #expect(script.contains("Dialogue: 0,0:01:01.50,0:01:03.88,Default,,0,0,0,,Hello {\\i1}there{\\i0}"))
    }

    @Test("Dedupes identical re-emits by content")
    func contentDedupe() {
        let b = ASSScriptBuilder(header: header)
        #expect(b.add(rawEventText: "7,0,Default,,0,0,0,,First", start: 1, end: 2))
        #expect(!b.add(rawEventText: "7,0,Default,,0,0,0,,First", start: 1, end: 2))
        #expect(b.eventCount == 1)
    }

    @Test("Keeps distinct events that share a ReadOrder")
    func sharedReadOrderKept() {
        // Real files ship ReadOrder hardcoded to 0 on every line; the
        // whole track must not collapse to one event (field repro).
        let b = ASSScriptBuilder(header: header)
        #expect(b.add(rawEventText: "0,,Default,,0,0,0,,Erste Zeile", start: 1, end: 2))
        #expect(b.add(rawEventText: "0,,Default,,0,0,0,,Zweite Zeile", start: 3, end: 4))
        #expect(b.eventCount == 2)
        let script = b.script()
        #expect(script.contains(",Erste Zeile"))
        #expect(script.contains(",Zweite Zeile"))
    }

    @Test("Strips NUL bytes from the header")
    func nulStrippedHeader() {
        // MKV CodecPrivate is frequently NUL-terminated; libass parses
        // C-string-style and would ignore everything after the NUL.
        let b = ASSScriptBuilder(header: "[Script Info]\r\nPlayResX: 960\r\n\u{0000}")
        b.add(rawEventText: "0,0,Default,,0,0,0,,Hi", start: 0, end: 1)
        let script = b.script()
        #expect(!script.contains("\u{0000}"))
        #expect(script.contains("[Events]"))
        #expect(script.contains("Dialogue: 0,"))
    }

    @Test("Orders events by cue start time")
    func orderedByStart() {
        let b = ASSScriptBuilder(header: header)
        b.add(rawEventText: "0,,Default,,0,0,0,,Later", start: 10, end: 11)
        b.add(rawEventText: "0,,Default,,0,0,0,,Earlier", start: 5, end: 6)
        let script = b.script()
        let earlier = script.range(of: ",Earlier")!.lowerBound
        let later = script.range(of: ",Later")!.lowerBound
        #expect(earlier < later)
    }

    @Test("Splits multi-line cue bodies into separate events")
    func multiLineBody() {
        let b = ASSScriptBuilder(header: header)
        #expect(b.add(rawEventText: "1,0,Default,,0,0,0,,Top\n2,0,Default,,0,0,0,,Bottom", start: 0, end: 4))
        #expect(b.eventCount == 2)
    }

    @Test("Text field keeps embedded commas intact")
    func commasInText() {
        let b = ASSScriptBuilder(header: header)
        #expect(b.add(rawEventText: "9,1,Sign,Actor,10,20,30,fx,One, two, three", start: 0, end: 1))
        #expect(b.script().contains("Dialogue: 1,0:00:00.00,0:00:01.00,Sign,Actor,10,20,30,fx,One, two, three"))
    }

    @Test("Hour-plus timestamps and centisecond rounding")
    func timestampEdges() {
        #expect(ASSScriptBuilder.timestamp(3661.01) == "1:01:01.01")
        #expect(ASSScriptBuilder.timestamp(0) == "0:00:00.00")
        #expect(ASSScriptBuilder.timestamp(-3) == "0:00:00.00")
        #expect(ASSScriptBuilder.timestamp(35999.999) == "10:00:00.00")
    }

    @Test("Malformed lines are skipped, reset clears state")
    func malformedAndReset() {
        let b = ASSScriptBuilder(header: header)
        #expect(!b.add(rawEventText: "no-commas-here", start: 0, end: 1))
        #expect(b.add(rawEventText: "3,0,Default,,0,0,0,,Ok", start: 0, end: 1))
        b.reset()
        #expect(b.eventCount == 0)
        #expect(b.add(rawEventText: "3,0,Default,,0,0,0,,Ok", start: 0, end: 1))
    }

    @Test("Out-of-order arrival renders sorted by ReadOrder")
    func outOfOrderArrival() {
        let b = ASSScriptBuilder(header: header)
        b.add(rawEventText: "4,0,Default,,0,0,0,,Later", start: 10, end: 11)
        b.add(rawEventText: "2,0,Default,,0,0,0,,Earlier", start: 5, end: 6)
        let script = b.script()
        let earlier = script.range(of: ",Earlier")!.lowerBound
        let later = script.range(of: ",Later")!.lowerBound
        #expect(earlier < later)
    }

    @Test("Empty builder renders just the header; distinct content with the same ReadOrder is kept")
    func emptyAndDistinctContent() {
        let b = ASSScriptBuilder(header: header)
        #expect(b.script() == header)
        b.add(rawEventText: "6,0,Default,,0,0,0,,Original", start: 1, end: 2)
        b.add(rawEventText: "6,0,Default,,0,0,0,,Changed", start: 9, end: 10)
        let script = b.script()
        #expect(script.contains(",Original"))
        #expect(script.contains(",Changed"))
    }

    @Test("Synthesizes the Events section when the header lacks it")
    func missingEventsSection() {
        // MKV codec private data usually ends after the last Style line
        // (no [Events] section); without synthesizing one, Dialogue
        // lines land inside [V4+ Styles] and libass parses 0 events.
        let bareHeader = """
        [Script Info]
        PlayResX: 960

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,sans-serif,47
        """
        let b = ASSScriptBuilder(header: bareHeader)
        b.add(rawEventText: "1,0,Default,,0,0,0,,Hi", start: 0, end: 1)
        let script = b.script()
        let eventsRange = script.range(of: "[Events]")
        let formatRange = script.range(of: "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")
        let dialogueRange = script.range(of: "Dialogue: 0,")
        #expect(eventsRange != nil)
        #expect(formatRange != nil)
        #expect(dialogueRange != nil)
        if let e = eventsRange, let f = formatRange, let d = dialogueRange {
            #expect(e.lowerBound < f.lowerBound)
            #expect(f.lowerBound < d.lowerBound)
        }
    }

    @Test("Does not duplicate an existing Events section")
    func existingEventsSection() {
        let b = ASSScriptBuilder(header: header)  // suite header HAS [Events]
        b.add(rawEventText: "1,0,Default,,0,0,0,,Hi", start: 0, end: 1)
        let script = b.script()
        #expect(script.components(separatedBy: "[Events]").count == 2)
    }
}
