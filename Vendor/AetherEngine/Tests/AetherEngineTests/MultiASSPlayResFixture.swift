import Foundation
import CoreGraphics

/// A 2.8 KB Matroska container with one video stream and TWO ASS subtitle streams that declare
/// DIFFERENT `PlayResX/Y` while carrying the SAME `\pos` coordinates (AE#266 follow-up).
///
/// The identical `\pos(320,240)` in both scripts is the point: the normalized placement can only
/// differ if each stream normalizes against its own header, so a decode that pins one PlayRes for
/// the whole container produces two equal positions and is caught. Comparing the passed-through
/// `assHeader` instead would not catch it, since the extradata is per stream either way.
///
/// Embedded rather than checked in as a binary so CI runs it without a fixture fetch; regenerate
/// with (the second script is the first with PlayRes 1920x1080, the times shifted 0.5 s and the
/// Spanish lines):
///
///     ffmpeg -f lavfi -i color=c=black:s=16x16:r=1:d=1 -i en.ass -i es.ass \
///       -map 0:v -map 1:0 -map 2:0 -c:v libx264 -preset ultrafast -crf 51 -pix_fmt yuv420p -c:s copy \
///       -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa multi-ass.mkv
///
/// Stream layout: 0 = h264 video, 1 = ass (eng, 640x480), 2 = ass (spa, 1920x1080).
enum MultiASSPlayResFixture {

    /// Absolute AVStream index of the English ASS stream, whose header declares 640x480.
    static let englishStreamIndex: Int32 = 1
    /// Absolute AVStream index of the Spanish ASS stream, whose header declares 1920x1080.
    static let spanishStreamIndex: Int32 = 2
    /// Absolute AVStream index of the video stream: a valid stream that is not a subtitle stream.
    static let videoStreamIndex: Int32 = 0

    static let englishLines = ["first english line", "second english line"]
    static let spanishLines = ["primera linea espanola", "segunda linea espanola"]

    /// The `\pos` both first cues carry, verbatim from the two scripts.
    static let sharedPositionTag = CGPoint(x: 320, y: 240)
    static let englishPlayRes = CGSize(width: 640, height: 480)
    static let spanishPlayRes = CGSize(width: 1920, height: 1080)

    /// `\pos` normalized against the stream's own declared play resolution.
    static let englishPosition = CGPoint(x: sharedPositionTag.x / englishPlayRes.width,
                                         y: sharedPositionTag.y / englishPlayRes.height)
    static let spanishPosition = CGPoint(x: sharedPositionTag.x / spanishPlayRes.width,
                                         y: sharedPositionTag.y / spanishPlayRes.height)

    /// Write the container to a unique temporary file and return its URL. The caller owns the file;
    /// `withFixture` removes it.
    static func write() throws -> URL {
        guard let data = Data(base64Encoded: base64.joined()) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae266-multi-ass-\(UUID().uuidString).mkv")
        try data.write(to: url)
        return url
    }

    /// Run `body` against a freshly written container, removing it afterwards.
    static func withFixture<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = try write()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    private static let base64 = [
        "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAKyxFNm3TAv4T5RQjKTbuLU6uEFUmpZlOs",
        "gaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIF9027jFOrhBxTu2tTrIIKU+wBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsu/hLI6N2Iq",
        "17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJDTTNVFyiwzN8MpTYpxzPBkRImIQLGUAAAAAAAWVK5rRQC/",
        "hE5hmnauAQAAAAAAAIDXgQFzxYiYVEuL/2LqlJyBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OBASPjg4Q7msoA4JCwgRC6",
        "gRCagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAY6KlAULACv/hABVnQsAK2nsBEAAAAwAQAAADACDxImoBAAVozgGXIK4BAAAAAAAC",
        "LdeBAnPFiKmJ+AnIaDNgnIEAIrWcg2VuZ4aKU19URVhUL0FTU4OBEVXugQBjokH+W1NjcmlwdCBJbmZvXQpTY3JpcHRUeXBlOiB2",
        "NC4wMCsKUGxheVJlc1g6IDY0MApQbGF5UmVzWTogNDgwCgpbVjQrIFN0eWxlc10KRm9ybWF0OiBOYW1lLCBGb250bmFtZSwgRm9u",
        "dHNpemUsIFByaW1hcnlDb2xvdXIsIFNlY29uZGFyeUNvbG91ciwgT3V0bGluZUNvbG91ciwgQmFja0NvbG91ciwgQm9sZCwgSXRh",
        "bGljLCBVbmRlcmxpbmUsIFN0cmlrZU91dCwgU2NhbGVYLCBTY2FsZVksIFNwYWNpbmcsIEFuZ2xlLCBCb3JkZXJTdHlsZSwgT3V0",
        "bGluZSwgU2hhZG93LCBBbGlnbm1lbnQsIE1hcmdpbkwsIE1hcmdpblIsIE1hcmdpblYsIEVuY29kaW5nClN0eWxlOiBEZWZhdWx0",
        "LEFyaWFsLDIwLCZIMDBGRkZGRkYsJkgwMDAwMDBGRiwmSDAwMDAwMDAwLCZIMDAwMDAwMDAsMCwwLDAsMCwxMDAsMTAwLDAsMCwx",
        "LDEsMCwyLDEwLDEwLDEwLDEKCltFdmVudHNdCkZvcm1hdDogTGF5ZXIsIFN0YXJ0LCBFbmQsIFN0eWxlLCBOYW1lLCBNYXJnaW5M",
        "LCBNYXJnaW5SLCBNYXJnaW5WLCBFZmZlY3QsIFRleHQKrgEAAAAAAAIy14EDc8WIxKVAcJHhb3ucgQAitZyDc3BhiIEAhopTX1RF",
        "WFQvQVNTg4ERVe6BAGOiQgBbU2NyaXB0IEluZm9dClNjcmlwdFR5cGU6IHY0LjAwKwpQbGF5UmVzWDogMTkyMApQbGF5UmVzWTog",
        "MTA4MAoKW1Y0KyBTdHlsZXNdCkZvcm1hdDogTmFtZSwgRm9udG5hbWUsIEZvbnRzaXplLCBQcmltYXJ5Q29sb3VyLCBTZWNvbmRh",
        "cnlDb2xvdXIsIE91dGxpbmVDb2xvdXIsIEJhY2tDb2xvdXIsIEJvbGQsIEl0YWxpYywgVW5kZXJsaW5lLCBTdHJpa2VPdXQsIFNj",
        "YWxlWCwgU2NhbGVZLCBTcGFjaW5nLCBBbmdsZSwgQm9yZGVyU3R5bGUsIE91dGxpbmUsIFNoYWRvdywgQWxpZ25tZW50LCBNYXJn",
        "aW5MLCBNYXJnaW5SLCBNYXJnaW5WLCBFbmNvZGluZwpTdHlsZTogRGVmYXVsdCxBcmlhbCwyMCwmSDAwRkZGRkZGLCZIMDAwMDAw",
        "RkYsJkgwMDAwMDAwMCwmSDAwMDAwMDAwLDAsMCwwLDAsMTAwLDEwMCwwLDAsMSwxLDAsMiwxMCwxMCwxMCwxCgpbRXZlbnRzXQpG",
        "b3JtYXQ6IExheWVyLCBTdGFydCwgRW5kLCBTdHlsZSwgTmFtZSwgTWFyZ2luTCwgTWFyZ2luUiwgTWFyZ2luViwgRWZmZWN0LCBU",
        "ZXh0ChJUw2dA7b+E+Rqk93NzoGPAgGfImkWjh0VOQ09ERVJEh41MYXZmNjIuMTIuMTAxc3PXY8CLY8WImFRLi/9i6pRnyKJFo4dF",
        "TkNPREVSRIeVTGF2YzYyLjI4LjEwMSBsaWJ4MjY0Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMS4wMDAwMDAwMDAAc3OyY8CLY8WI",
        "qYn4CchoM2BnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjA0LjAwMDAwMDAwMABzc7JjwItjxYjEpUBwkeFve2fIoUWjiERVUkFUSU9O",
        "RIeTMDA6MDA6MDQuNTAwMDAwMDAwAB9DtnVDY7+E5tnNxeeBAKNCaIEAAIAAAAJTBgX//0/cRem95tlIt5Ys2CDZI+7veDI2NCAt",
        "IGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0",
        "cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5",
        "c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21h",
        "X21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0",
        "PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNl",
        "ZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlp",
        "bnRfbWluPTEgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj01MS4wIHFjb21wPTAuNjAgcXBt",
        "aW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAAlliIQ6JigAFcCgv6G5ggPoADAsMCxEZWZhdWx0",
        "LCwwLDAsMCwse1xwb3MoMzIwLDI0MCl9Zmlyc3QgZW5nbGlzaCBsaW5lm4ID6KDDob2DBdwAMCwwLERlZmF1bHQsLDAsMCwwLCx7",
        "XHBvcygzMjAsMjQwKX1wcmltZXJhIGxpbmVhIGVzcGFub2xhm4ID6KCxoauCC7gAMSwwLERlZmF1bHQsLDAsMCwwLCxzZWNvbmQg",
        "ZW5nbGlzaCBsaW5lm4ID6KC0oa6DDawAMSwwLERlZmF1bHQsLDAsMCwwLCxzZWd1bmRhIGxpbmVhIGVzcGFub2xhm4ID6BxTu2vz",
        "v4SL+WReu4+zgQC3iveBAfGCBurwgQm7lbOCA+i3j/eBAvGCBurwggJ0soID6LuVs4IF3LeP94ED8YIG6vCCArWyggPou5Wzggu4",
        "t4/3gQLxggbq8IIC+rKCA+i7lbOCDay3j/eBA/GCBurwggMtsoID6A==",
    ]
}
