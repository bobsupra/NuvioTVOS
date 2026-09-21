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

    // MARK: - Credentials that no key name points at

    /// Reported privately against 6.70.0. Several debrid and proxy add-ons in the Stremio ecosystem
    /// carry the account token in a PATH segment, as base64url-encoded JSON, with no parameter name
    /// anywhere near it, so every matcher above walks straight past it.
    ///
    /// Adding names cannot reach this one, and the decoded payload is why: its keys are `stores`, `c`
    /// and `t`. Matching key names inside the decoded JSON would still miss it. The encoding itself is
    /// the only thing that marks the segment as a carrier, so that is what this matches on.
    @Test("a credential encoded into a path segment goes, although nothing in the line names it")
    func encodedPathSegment() {
        // {"stores":[{"c":"tb","t":"9f2c1ab34de5470fa1b6c8d90e7f2a11abcd"}]}
        let segment = "eyJzdG9yZXMiOlt7ImMiOiJ0YiIsInQiOiI5ZjJjMWFiMzRkZTU0NzBmYTFiNmM4ZDkwZTdmMmExMWFiY2QifV19"
        let line = LogRedaction.redact(
            "[AetherEngine] load url=https://proxy.example.org/stremio/torz/\(segment)" +
            "/_/strem/tt0111161/tb/9a3f/0/Some.Film.2009.mkv source-format=mkv"
        )
        #expect(!line.contains(segment))
        #expect(!line.contains("ImMiOiJ0YiIsInQi"))
        #expect(line.contains("/stremio/torz/<redacted>/_/strem/"))
        #expect(line.contains("proxy.example.org"))
        #expect(line.contains("Some.Film.2009.mkv"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    /// The same shape without a key name, in the other place a URL hides one. `config=` is not a
    /// credential parameter and never will be, so the value has to answer for itself.
    @Test("an encoded blob in a query value goes even though its parameter is not a credential name")
    func encodedQueryValue() {
        let segment = "eyJzdG9yZXMiOlt7ImMiOiJ0YiIsInQiOiI5ZjJjMWFiMzRkZTU0NzBmYTFiNmM4ZDkwZTdmMmExMWFiY2QifV19"
        let line = LogRedaction.redact("[x] https://s/a?config=\(segment)&Static=true")
        #expect(!line.contains(segment))
        #expect(line == "[x] https://s/a?config=<redacted>&Static=true")
    }

    /// A bearer token is the other nameless carrier: `Authorization` is not a credential key, `Bearer`
    /// is a scheme, and the secret is the signature at the end. All three parts go, since a JWT missing
    /// only its header is still a JWT to anyone who knows the algorithm.
    @Test("a bearer JSON web token goes whole, signature included")
    func bearerJSONWebToken() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ"
            + ".dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXkw"
        let line = LogRedaction.redact("[http] GET /Items Authorization: Bearer \(jwt)")
        #expect(!line.contains("dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXkw"))
        #expect(!line.contains("eyJzdWIiOiIxMjM0NTY3ODkw"))
        #expect(line == "[http] GET /Items Authorization: Bearer <redacted>")
    }

    /// The other nameless carrier, found by comparing this file against the copy Sodalite kept: a URL
    /// can put the credential in its authority, where no key precedes it either. `load url=` logs
    /// `absoluteString`, so a share opened as `smb://user:pw@host` or a server behind basic auth walked
    /// straight into all three sinks. The user name stays: a log that cannot say which account failed
    /// is worth less, and the name is not the secret.
    @Test("a password in the authority goes, and the account name it identifies stays", arguments: [
        "smb://media-ro:\(#"hunter2secretpw"#)@nas.local/Films/A.mkv",
        "https://media-ro:\(#"hunter2secretpw"#)@jf.example.org/Videos/abc/stream.mkv",
    ])
    func userInfoInTheAuthority(url: String) {
        let line = LogRedaction.redact("[AetherEngine] load url=\(url) source-format=mkv")
        #expect(!line.contains("hunter2secretpw"))
        #expect(line.contains("media-ro:<redacted>@"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    /// The gate has to be the encoding, not a resemblance to it. An episode file that happens to start
    /// with the same two letters, an item id, a hash: all of these are what a playback report is
    /// actually diagnosed from, and none of them may be swallowed.
    @Test("an ordinary segment that merely looks encoded is left alone", arguments: [
        "[AetherEngine] load url=https://s/Videos/Eyewitness.S01E04.mkv source-format=mkv",
        "[AetherEngine] load url=https://s/Videos/eyewitness-report-2011.mkv source-format=mkv",
        "[AetherEngine] load url=https://s/Videos/a1b2c3d4e5f60718293a4b5c6d7e8f90/stream.mkv?Static=true",
        "[hls.server] GET /master.m3u8 -> 200",
    ])
    func ordinarySegmentsSurvive(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    /// The point of putting this in EngineLog rather than in each host: the handler a host installs
    /// must never see the raw token, whether or not that host scrubs its own log.
    @Test("the host handler receives the redacted line")
    func handlerSeesRedactedLine() {
        let box = LineBox()
        let previous = EngineLog.handler
        EngineLog.handler = { box.append($0) }
        defer { EngineLog.handler = previous }

        EngineLog.emit("[test-496a] load url=https://s/v?api_key=\(token)&Static=true", category: .engine)

        // #496: the handler is a process-wide singleton, so every line any concurrently running
        // suite emits lands in this box too. Assert on THIS test's line, not on the box.
        let captured = box.lines.filter { $0.contains("[test-496a]") }
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

        EngineLog.emit("[test-496b] per-segment trace api_key=\(token)", category: .session, level: .verbose)

        // #496: same singleton, same rule. The bare `box.lines.isEmpty` failed a full run once on
        // an unrelated AVIOReader line from a parallel suite, which says nothing about `.verbose`.
        #expect(box.lines.filter { $0.contains("[test-496b]") }.isEmpty)
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
