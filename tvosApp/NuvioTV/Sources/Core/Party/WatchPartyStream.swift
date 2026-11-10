import Foundation

// Android wire contract: PartyModels.kt / domain/model/Stream.kt (GPL-3.0), f7e2a78.
struct WatchPartyStreamBadge: Codable, Equatable, Sendable {
    var name: String
    var imageURL: String = ""
    var tagColor: String = ""
    var tagStyle: String = ""
    var textColor: String = ""
    var borderColor: String = ""
}

extension WatchPartyStreamBadge {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  imageURL: try c.decodeIfPresent(String.self, forKey: .imageURL) ?? "",
                  tagColor: try c.decodeIfPresent(String.self, forKey: .tagColor) ?? "",
                  tagStyle: try c.decodeIfPresent(String.self, forKey: .tagStyle) ?? "",
                  textColor: try c.decodeIfPresent(String.self, forKey: .textColor) ?? "",
                  borderColor: try c.decodeIfPresent(String.self, forKey: .borderColor) ?? "")
    }
}

struct WatchPartyStream: Codable, Equatable, Sendable {
    var mediaKey: String
    var url: String
    var headers: [String: String] = [:]
    var responseHeaders: [String: String] = [:]
    var name: String? = nil
    var description: String? = nil
    var addonName: String = ""
    var addonID: String = ""
    var addonLogo: String? = nil
    var filename: String? = nil
    var videoSize: Int64? = nil
    var bingeGroup: String? = nil
    var streamType: String? = nil
    var badges: [WatchPartyStreamBadge] = []

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key", url, headers, responseHeaders = "response_headers", name, description
        case addonName = "addon_name", addonID = "addon_id", addonLogo = "addon_logo", filename
        case videoSize = "video_size", bingeGroup = "binge_group", streamType = "stream_type", badges
    }

    /// Keep metadata that NuvioStream cannot represent attached to the playable candidate.
    /// The future engine binding must handle response headers explicitly; never send them as request headers.
    func playbackCandidate() throws -> WatchPartyStreamCandidate {
        try WatchPartyStreamPolicy.validate(self)
        let stream = NuvioStream(url: url, name: name, description: description,
                                 addonName: addonName, addonLogoURL: addonLogo,
                                 filename: filename, videoSize: videoSize, bingeGroup: bingeGroup,
                                 httpHeaders: headers.isEmpty ? nil : headers)
        return WatchPartyStreamCandidate(stream: stream, metadata: self)
    }

    /// The runtime must supply its resolved URL and effective headers, not a stale discovery URL.
    /// This only builds an inert payload; it grants no consent and sends nothing.
    static func fromPlayback(_ source: NuvioStream, mediaKey: String, resolvedURL: String,
                             requestHeaders: [String: String], responseHeaders: [String: String],
                             origin: WatchPartyStreamOrigin, addonID: String = "", streamType: String? = nil,
                             badges: [WatchPartyStreamBadge] = []) throws -> WatchPartyStream {
        guard origin == .directHTTP, !source.isNotPlayable else { throw WatchPartyStreamError.unsupportedSource }
        let value = WatchPartyStream(mediaKey: mediaKey, url: resolvedURL, headers: requestHeaders,
                                     responseHeaders: responseHeaders, name: source.name, description: source.description,
                                     addonName: source.addonName ?? "", addonID: addonID, addonLogo: source.addonLogoURL,
                                     filename: source.filename, videoSize: source.videoSize, bingeGroup: source.bingeGroup,
                                     streamType: streamType, badges: badges)
        try WatchPartyStreamPolicy.validate(value)
        return value
    }
}

extension WatchPartyStream {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mediaKey: try c.decode(String.self, forKey: .mediaKey),
                  url: try c.decode(String.self, forKey: .url),
                  headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                  responseHeaders: try c.decodeIfPresent([String: String].self, forKey: .responseHeaders) ?? [:],
                  name: try c.decodeIfPresent(String.self, forKey: .name),
                  description: try c.decodeIfPresent(String.self, forKey: .description),
                  addonName: try c.decodeIfPresent(String.self, forKey: .addonName) ?? "",
                  addonID: try c.decodeIfPresent(String.self, forKey: .addonID) ?? "",
                  addonLogo: try c.decodeIfPresent(String.self, forKey: .addonLogo),
                  filename: try c.decodeIfPresent(String.self, forKey: .filename),
                  videoSize: try c.decodeIfPresent(Int64.self, forKey: .videoSize),
                  bingeGroup: try c.decodeIfPresent(String.self, forKey: .bingeGroup),
                  streamType: try c.decodeIfPresent(String.self, forKey: .streamType),
                  badges: try c.decodeIfPresent([WatchPartyStreamBadge].self, forKey: .badges) ?? [])
    }
}

/// Presentation-only guest status. Never expose URL, query, headers or source metadata.
/// Realtime stream events are not persisted in room snapshots. An absent stream
/// is not proof that the host never shared; it may have been sent before joining
/// or cleared when the connection was lost.
enum WatchPartySharedSourceNotice {
    static func text(hostName: String?, stream: WatchPartyStream?, mediaKey: String,
                     isGuest: Bool, connected: Bool) -> String? {
        guard isGuest, connected else { return nil }
        let raw = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultHost = L10n.string("party_the_host", fallback: "The host")
        let name = raw.isEmpty ? defaultHost : String(raw.prefix(48))
        if let stream, stream.mediaKey == mediaKey {
            return L10n.format(
                "party_shared_source_available",
                fallback: "%@ shared a source (Beta). Select Use host's source to try it, or choose your own source. Provider restrictions may apply.",
                name
            )
        }
        return L10n.format(
            "party_shared_source_unavailable",
            fallback: "No shared source available right now. If %@ already shared a link, ask them to share it again. Or choose your own source.",
            name
        )
    }
}

struct WatchPartyStreamCandidate {
    let stream: NuvioStream
    let metadata: WatchPartyStream
    var responseHeaders: [String: String] { metadata.responseHeaders }
}

struct WatchPartyStreamMessage: Codable {
    let memberID: String
    let stream: WatchPartyStream?
    enum CodingKeys: String, CodingKey { case memberID = "member_id", stream }

    init(memberID: String, stream: WatchPartyStream?) { self.memberID = memberID; self.stream = stream }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberID = try c.decode(String.self, forKey: .memberID)
        // Missing key is malformed; explicit null revokes sharing as on Android.
        stream = try c.decode(WatchPartyStream?.self, forKey: .stream)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(memberID, forKey: .memberID)
        if let stream { try c.encode(stream, forKey: .stream) } else { try c.encodeNil(forKey: .stream) }
    }
}
