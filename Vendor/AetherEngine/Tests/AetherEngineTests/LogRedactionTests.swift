import Foundation
import Testing
@testable import AetherEngine

/// The engine logs whole URLs so a report can be diagnosed from host, path and query. Media servers put
/// the access token in that same query, and `EngineLog` emits with `.public` privacy into OSLog plus
/// whatever handler the host installed, so an unredacted line is a live credential in a Console.app
/// capture, a sysdiagnose, and every in-app log a host builds on the handler.
/// Serialized: `EngineLog.handler` is process-global, so two of these running at once would
/// each install over the other and read an empty capture.
@Suite("EngineLog credential stripping", .serialized)
struct LogRedactionTests {

    private let token = "9f2c1ab34de5470fa1b6c8d90e7f2a11"

    @Test("a media-server stream URL loses its api_key and keeps what diagnoses the report")
    func streamURLQuery() {
        let line = LogRedaction.redact(
            "[AetherEngine] load url=https://media.example.org/Videos/abc123/stream.mkv" +
            "?api_key=\(token)&Static=true&MediaSourceId=abc123 source-format=mkv"
        )
        #expect(!line.contains(token))
        #expect(line.contains("api_key=<redacted>"))
        #expect(line.contains("media.example.org/Videos/abc123/stream.mkv"))
        #expect(line.contains("Static=true"))
        #expect(line.contains("MediaSourceId=abc123"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    @Test("the generic credential parameter names are covered", arguments: [
        "api_key", "ApiKey", "access_token", "token", "password", "secret", "signature",
        "X-Emby-Token", "X-MediaBrowser-Token",
    ])
    func genericKeyNames(key: String) {
        let line = LogRedaction.redact("[x] https://s/a?\(key)=\(token)&keep=1")
        #expect(!line.contains(token))
        #expect(line == "[x] https://s/a?\(key)=<redacted>&keep=1")
    }

    @Test("the quoted header form is stripped inside its quotes")
    func quotedHeaderForm() {
        let line = LogRedaction.redact(#"Authorization: MediaBrowser Client="Host", Token="\#(token)", Device="TV""#)
        #expect(!line.contains(token))
        #expect(line.contains(#"Token="<redacted>""#))
        #expect(line.contains(#"Client="Host""#))
        #expect(line.contains(#"Device="TV""#))
    }

    @Test("the colon-separated header form is stripped")
    func colonSeparatedHeader() {
        let line = LogRedaction.redact("[http] X-Emby-Token: \(token) sent")
        #expect(line == "[http] X-Emby-Token: <redacted> sent")
    }

    @Test("a session cookie is stripped up to the attribute separator")
    func cookieForm() {
        let line = LogRedaction.redact("[net] connect.sid=s%3Aabc.def+ghi; Path=/; HttpOnly")
        #expect(!line.contains("s%3Aabc.def"))
        #expect(line == "[net] connect.sid=<redacted>; Path=/; HttpOnly")
    }

    @Test("a colon after the value ends it, so the error text survives")
    func colonTerminatesTheValue() {
        let line = LogRedaction.redact("[Image] fetch failed https://s/i?ApiKey=\(token): timeout")
        #expect(line.hasSuffix(": timeout"))
        #expect(line.contains("ApiKey=<redacted>"))
    }

    /// The broad `token` and `secret` keys must not fire mid-identifier, or the per-second counters the
    /// engine exists to report start reading as redactions.
    @Test("a key substring inside another identifier is left alone", arguments: [
        "[session] hasToken=true refreshTokenAt=120s",
        "[SWDiag] enq=48 layerDrop=0 delay=0.02 cushion=1.8",
        "[LiveDirect] eligible: route=hls tuner=file",
        "[HLSVideoEngine] serving on http://127.0.0.1:52341/master.m3u8 (dvModeAvailable=true)",
        "[DisplayCriteria] refreshRate=23.976 videoRange=HLG",
    ])
    func doesNotFireMidIdentifier(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    @Test("an empty value and a bare mention are left alone")
    func nothingToStrip() {
        #expect(LogRedaction.redact("[auth] api_key= (missing)") == "[auth] api_key= (missing)")
        #expect(LogRedaction.redact("no token was supplied") == "no token was supplied")
    }

    @Test("several credentials in one line are all stripped")
    func multiplePerLine() {
        let line = LogRedaction.redact("a=1&api_key=\(token)&b=2&access_token=\(token)&c=3")
        #expect(!line.contains(token))
        #expect(line == "a=1&api_key=<redacted>&b=2&access_token=<redacted>&c=3")
    }

    /// The point of putting this in EngineLog rather than in each host: the handler a host installs
    /// must never see the raw token, whether or not that host scrubs its own log.
    @Test("the host handler receives the redacted line")
    func handlerSeesRedactedLine() {
        let box = LineBox()
        let previous = EngineLog.handler
        EngineLog.handler = { box.append($0) }
        defer { EngineLog.handler = previous }

        EngineLog.emit("[test] load url=https://s/v?api_key=\(token)&Static=true", category: .engine)

        let captured = box.lines
        #expect(captured.count == 1)
        #expect(captured.first?.contains("api_key=<redacted>") == true)
        #expect(captured.first?.contains(token) == false)
        #expect(captured.first?.contains("Static=true") == true)
    }

    /// `.verbose` never reaches the handler; it still goes to OSLog, which is why redaction sits on the
    /// shared funnel and not on the `.info` branch alone.
    @Test("a verbose line is withheld from the handler")
    func verboseSkipsTheHandler() {
        let box = LineBox()
        let previous = EngineLog.handler
        EngineLog.handler = { box.append($0) }
        defer { EngineLog.handler = previous }

        EngineLog.emit("[test] per-segment trace api_key=\(token)", category: .session, level: .verbose)

        #expect(box.lines.isEmpty)
    }

    /// The handler is called on whatever thread emitted, so the capture needs its own lock.
    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(line)
        }

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}
