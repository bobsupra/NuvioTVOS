import Testing
@testable import AetherEngine

@Suite("FontAttachment classification")
struct FontAttachmentTests {
    @Test("Recognizes font MIME types")
    func mimeTypes() {
        #expect(FontAttachment.isFontPayload(mimeType: "font/ttf", filename: nil))
        #expect(FontAttachment.isFontPayload(mimeType: "font/otf", filename: nil))
        #expect(FontAttachment.isFontPayload(mimeType: "font/sfnt", filename: nil))
        #expect(FontAttachment.isFontPayload(mimeType: "application/x-truetype-font", filename: nil))
        #expect(FontAttachment.isFontPayload(mimeType: "application/vnd.ms-opentype", filename: nil))
        #expect(FontAttachment.isFontPayload(mimeType: "application/font-sfnt", filename: nil))
        #expect(FontAttachment.isFontPayload(mimeType: "application/x-font-ttf", filename: nil))
        #expect(!FontAttachment.isFontPayload(mimeType: "image/jpeg", filename: "cover.jpg"))
    }

    @Test("Falls back to filename extension for generic MIME")
    func extensionFallback() {
        #expect(FontAttachment.isFontPayload(mimeType: "application/octet-stream", filename: "OpenSans.ttf"))
        #expect(FontAttachment.isFontPayload(mimeType: nil, filename: "Style.OTF"))
        #expect(FontAttachment.isFontPayload(mimeType: nil, filename: "fonts.TTC"))
        #expect(!FontAttachment.isFontPayload(mimeType: "application/octet-stream", filename: "notes.txt"))
        #expect(!FontAttachment.isFontPayload(mimeType: nil, filename: nil))
        // A declared non-font MIME wins over a font-looking extension.
        #expect(!FontAttachment.isFontPayload(mimeType: "image/jpeg", filename: "logo.ttf"))
    }
}
