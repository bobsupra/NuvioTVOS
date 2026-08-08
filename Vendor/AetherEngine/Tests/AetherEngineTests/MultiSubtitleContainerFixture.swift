import Foundation

/// A 1.7 KB Matroska container carrying one video stream and TWO subtitle streams (AE#266), so a
/// test can prove that a requested index addresses the ABSOLUTE AVStream index and not the Nth
/// subtitle stream. Embedded rather than checked in as a binary so CI runs it without a fixture
/// fetch; regenerate with:
///
///     printf '1\n00:00:01,000 --> 00:00:02,000\nfirst english line\n\n2\n00:00:03,000 --> 00:00:04,000\nsecond english line\n' > en.srt
///     printf '1\n00:00:01,500 --> 00:00:02,500\nprimera linea espanola\n\n2\n00:00:03,500 --> 00:00:04,500\nsegunda linea espanola\n' > es.srt
///     ffmpeg -f lavfi -i color=c=black:s=16x16:r=1:d=1 -i en.srt -i es.srt \
///       -map 0:v -map 1:0 -map 2:0 -c:v libx264 -preset ultrafast -crf 51 -pix_fmt yuv420p -c:s srt \
///       -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa multi-sub.mkv
///
/// Stream layout: 0 = h264 video, 1 = subrip (eng), 2 = subrip (spa).
enum MultiSubtitleContainerFixture {

    /// Absolute AVStream index of the English subtitle stream (the FIRST subtitle stream).
    static let englishStreamIndex: Int32 = 1
    /// Absolute AVStream index of the Spanish subtitle stream (the SECOND subtitle stream).
    static let spanishStreamIndex: Int32 = 2
    /// Absolute AVStream index of the video stream: a valid stream that is not a subtitle stream.
    static let videoStreamIndex: Int32 = 0

    static let englishLines = ["first english line", "second english line"]
    static let spanishLines = ["primera linea espanola", "segunda linea espanola"]

    /// Write the container to a unique temporary file and return its URL. The caller owns the file;
    /// `withFixture` removes it.
    static func write() throws -> URL {
        guard let data = Data(base64Encoded: base64.joined()) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae266-multi-sub-\(UUID().uuidString).mkv")
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
        "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAGmxFNm3TAv4SBEIGRTbuLU6uEFUmpZlOs",
        "gaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIB8027jFOrhBxTu2tTrIIGI+wBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsu/hEQd6VYq",
        "17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJDoHqoUxLLf3xWarpxu+IYgRImIQLGUAAAAAAAWVK5rQPy/",
        "hHnEsKOuAQAAAAAAAIDXgQFzxYhe/osBX0V8dpyBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OBASPjg4Q7msoA4JCwgRC6",
        "gRCagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAY6KlAULACv/hABVnQsAK2nsBEAAAAwAQAAADACDxImoBAAVozgGXIK4BAAAAAAAA",
        "LNeBAnPFiA6M8olhdHoOnIEAIrWcg2VuZ4aLU19URVhUL1VURjiDgRFV7oEArgEAAAAAAAAv14EDc8WIDwtfqsSY/9mcgQAitZyD",
        "c3BhiIEAhotTX1RFWFQvVVRGOIOBEVXugQASVMNnQS+/hCx91aNzc6BjwIBnyJpFo4dFTkNPREVSRIeNTGF2ZjYyLjEyLjEwMXNz",
        "12PAi2PFiF7+iwFfRXx2Z8iiRaOHRU5DT0RFUkSHlUxhdmM2Mi4yOC4xMDEgbGlieDI2NGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6",
        "MDEuMDAwMDAwMDAwAHNz02PAi2PFiA6M8olhdHoOZ8ieRaOHRU5DT0RFUkSHkUxhdmM2Mi4yOC4xMDEgc3J0Z8ihRaOIRFVSQVRJ",
        "T05Eh5MwMDowMDowNC4wMDAwMDAwMDAAc3PTY8CLY8WIDwtfqsSY/9lnyJ5Fo4dFTkNPREVSRIeRTGF2YzYyLjI4LjEwMSBzcnRn",
        "yKFFo4hEVVJBVElPTkSHkzAwOjAwOjA0LjUwMDAwMDAwMAAfQ7Z1QvW/hFFxCHLngQCjQmiBAACAAAACUwYF//9P3EXpvebZSLeW",
        "LNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIw",
        "MDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9j",
        "az0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3Jh",
        "bmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hy",
        "b21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0",
        "ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtl",
        "eWludD0yNTAga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9NTEuMCBx",
        "Y29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAAJZYiEOiYoABXAoJyhloID",
        "6ABmaXJzdCBlbmdsaXNoIGxpbmWbggPooKChmoMF3ABwcmltZXJhIGxpbmVhIGVzcGFub2xhm4ID6KCdoZeCC7gAc2Vjb25kIGVu",
        "Z2xpc2ggbGluZZuCA+igoKGagw2sAHNlZ3VuZGEgbGluZWEgZXNwYW5vbGGbggPoHFO7a/O/hBGUtNq7j7OBALeK94EB8YIDKPCB",
        "CbuVs4ID6LeP94EC8YIDKPCCAnSyggPou5WzggXct4/3gQPxggMo8IICkrKCA+i7lbOCC7i3j/eBAvGCAyjwggK0soID6LuVs4IN",
        "rLeP94ED8YIDKPCCAtOyggPo",
    ]
}
