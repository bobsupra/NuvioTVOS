import Foundation

/// Translates the source objects in Reshaped's `live_tv/<profile>/sources` section.
///
/// Reshaped uses string IDs and a type-specific identity. This app keeps UUIDs locally,
/// so imports reuse a local UUID when the canonical source identity already exists.
/// Credential fields are handled as data only and are never logged here.
enum IPTVReshapedSourceMapping {
    private static let importedFileType = "M3uFile"

    /// Matches `LiveTvSource.identity` in the upstream app.
    static func canonicalIdentity(for source: IPTVSource) -> String? {
        switch source.kind {
        case .m3u:
            guard !source.playlistURL.isEmpty else { return nil }
            return "m3u|\(source.playlistURL.lowercased())"
        case .xtream:
            guard let username = source.username, !username.isEmpty,
                  !source.playlistURL.isEmpty else { return nil }
            return "xtream|\(source.playlistURL.lowercased())|\(username)"
        case .stalker:
            guard let mac = source.mac, !mac.isEmpty, !source.playlistURL.isEmpty else { return nil }
            return "stalker|\(source.playlistURL.lowercased())|\(mac)"
        }
    }

    /// Returns nil for unsupported types, malformed entries, and imported playlist files.
    /// Imported files are deliberately not treated as M3U links: their `url` is a file name.
    static func canonicalIdentity(in fields: [String: Any]) -> String? {
        guard let type = fields["type"] as? String, type != importedFileType else { return nil }
        switch type {
        case "M3u":
            guard let url = nonemptyString(fields["url"]) else { return nil }
            return "m3u|\(url.lowercased())"
        case "Xtream":
            guard let server = nonemptyString(fields["server"]),
                  let username = nonemptyString(fields["user"]) else { return nil }
            return "xtream|\(server.lowercased())|\(username)"
        case "Stalker":
            guard let portal = nonemptyString(fields["portal"]),
                  let mac = nonemptyString(fields["mac"]) else { return nil }
            return "stalker|\(portal.lowercased())|\(mac)"
        default:
            return nil
        }
    }

    /// Imports a supported Reshaped source, retaining the local UUID on identity matches.
    /// `M3uFile` rows are unsupported imported-file references and are safely skipped.
    static func source(from fields: [String: Any], existingSources: [IPTVSource] = []) -> IPTVSource? {
        guard let type = fields["type"] as? String,
              let identity = canonicalIdentity(in: fields) else { return nil }

        let kind: IPTVSource.Kind
        let endpoint: String
        let username: String?
        let password: String?
        let mac: String?

        switch type {
        case "M3u":
            guard let url = nonemptyString(fields["url"]) else { return nil }
            kind = .m3u
            endpoint = url
            username = nil
            password = nil
            mac = nil
        case "Xtream":
            guard let server = nonemptyString(fields["server"]),
                  let user = nonemptyString(fields["user"]),
                  let pass = nonemptyString(fields["password"]) else { return nil }
            kind = .xtream
            endpoint = server
            username = user
            password = pass
            mac = nil
        case "Stalker":
            guard let portal = nonemptyString(fields["portal"]),
                  let address = nonemptyString(fields["mac"]) else { return nil }
            kind = .stalker
            endpoint = portal
            username = nonemptyString(fields["user"])
            password = nonemptyString(fields["password"])
            mac = address
        default:
            // `canonicalIdentity` rejects imported files and unknown source kinds.
            return nil
        }

        let name = resolvedName(nonemptyString(fields["name"]), endpoint: endpoint)
        let existing = existingSources.first(where: { canonicalIdentity(for: $0) == identity })
        let id = existing?.id ?? UUID()
        let xtreamOutput = kind == .xtream ? existing?.xtreamOutput ?? .mpegTS : .mpegTS
        return IPTVSource(id: id, name: name, playlistURL: endpoint, kind: kind,
                          username: username, password: password, mac: mac, xtreamOutput: xtreamOutput)
    }

    /// Updates represented fields on an existing source dictionary while retaining its
    /// upstream ID and fields this app does not model (for example `epg`, `ua`, and extras).
    /// The existing dictionary must describe the same supported source kind.
    static func merging(_ source: IPTVSource, into fields: [String: Any]) -> [String: Any]? {
        guard let upstreamType = fields["type"] as? String,
              canonicalIdentity(for: source) != nil,
              canonicalIdentity(in: fields) != nil,
              let localKind = sourceKind(for: upstreamType),
              localKind == source.kind,
              !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var updated = fields
        updated["name"] = source.name
        switch source.kind {
        case .m3u:
            updated["url"] = source.playlistURL
        case .xtream:
            guard let username = source.username, !username.isEmpty,
                  let password = source.password, !password.isEmpty else { return nil }
            updated["server"] = source.playlistURL
            updated["user"] = username
            updated["password"] = password
        case .stalker:
            guard let mac = source.mac, !mac.isEmpty else { return nil }
            updated["portal"] = source.playlistURL
            updated["mac"] = mac
            updated["user"] = source.username ?? ""
            updated["password"] = source.password ?? ""
        }

        // The upstream dictionary is selected by the caller before applying the edit;
        // edits may change the source's canonical identity.
        return updated
    }

    private static func sourceKind(for upstreamType: String) -> IPTVSource.Kind? {
        switch upstreamType {
        case "M3u": return .m3u
        case "Xtream": return .xtream
        case "Stalker": return .stalker
        default: return nil
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func resolvedName(_ name: String?, endpoint: String) -> String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if let host = URLComponents(string: endpoint)?.host, !host.isEmpty { return host }
        return endpoint
    }
}
