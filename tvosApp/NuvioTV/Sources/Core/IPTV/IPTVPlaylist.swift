// Adapted from Bro IPTV Player, PlaylistParser.swift, commit
// d9ad086685993ecd2ee82dc5479d25a105e569c1 (MIT).
// Copyright (c) 2026 Mikhail Demidov. See ThirdParty/BroIPTV-LICENSE.txt.
import Foundation

struct IPTVPlaylistParser {

    struct Playlist: Equatable, Sendable {
        let tvgURL: String? // URL to an archive with program guide
        let imageURL: String? // URL to an archive with images (png, jpg) for stream logos
        let xTvgURL: String? // Backup url for `tvgURL`
        let tvgLogo: String? // URL to the playlist's main logo image
        let streams: [Stream]
    }

    struct Stream: Sendable, Hashable {
        let title: String
        let url: String
        let tvgLogo: String?
        let tvgID: String?
        let tvgName: String?
        let groupTitle: String?
        /// An upstream-stable identifier, when supplied by a provider API.
        var providerID: String? = nil
    }

    enum ParserError: Error, Equatable {
        case invalidEncoding
        case invalidFormat
        case hlsPlaylist
    }

    private struct PlaylistBuilder {
        var tvgURL: String?
        var imageURL: String?
        var xTvgURL: String?
        var tvgLogo: String?
        var streams: [Stream] = []

        var playlist: Playlist {
            Playlist(
                tvgURL: tvgURL,
                imageURL: imageURL,
                xTvgURL: xTvgURL,
                tvgLogo: tvgLogo,
                streams: streams
            )
        }
    }

    private struct PendingStream {
        let title: String
        let tvgLogo: String?
        let tvgID: String?
        let tvgName: String?
        let groupTitle: String?

        func resolve(url: String) -> Stream {
            Stream(
                title: title,
                url: url,
                tvgLogo: tvgLogo,
                tvgID: tvgID,
                tvgName: tvgName,
                groupTitle: groupTitle
            )
        }
    }

    private static let m3uHeader = "#EXTM3U"
    private static let streamInfoHeader = "#EXTINF:"
    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z0-9_-]+)\s*=\s*("([^"]*)"|([^\s,]+))"#
    )

    private let content: String

    init(string: String) {
        content = Self.normalize(string)
    }

    init(data: Data, encoding: String.Encoding = .utf8) throws {
        guard let string = String(data: data, encoding: encoding) else {
            throw ParserError.invalidEncoding
        }

        content = Self.normalize(string)
    }

    func parse() throws -> [Playlist] {
        var playlists: [Playlist] = []
        var currentPlaylist: PlaylistBuilder?
        var pendingStream: PendingStream?
        var hasHeader = false
        do {
            for rawLine in content.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

                if line.isEmpty {
                    continue
                }

                if line.uppercased().hasPrefix("#EXT-X-") {
                    throw ParserError.hlsPlaylist
                }

                if line.hasPrefix(Self.m3uHeader) {
                    if let currentPlaylist {
                        playlists.append(currentPlaylist.playlist)
                    }

                    currentPlaylist = Self.buildPlaylist(from: line)
                    pendingStream = nil
                    hasHeader = true
                    continue
                }

                guard currentPlaylist != nil else {
                    continue
                }

                if line.hasPrefix(Self.streamInfoHeader) {
                    pendingStream = Self.buildStream(from: line)
                    continue
                }

                if line.hasPrefix("#") {
                    continue
                }

                guard let resolvedStream = pendingStream else {
                    continue
                }

                currentPlaylist?.streams.append(resolvedStream.resolve(url: line))
                pendingStream = nil
            }
        }

        guard hasHeader else {
            throw ParserError.invalidFormat
        }

        if let currentPlaylist {
            playlists.append(currentPlaylist.playlist)
        }


        return playlists
    }

    private static func normalize(_ string: String) -> String {
        let withoutBOM = string.hasPrefix("\u{feff}") ? String(string.dropFirst()) : string
        return withoutBOM
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func buildPlaylist(from line: String) -> PlaylistBuilder {
        let attributes = parseAttributes(in: String(line.dropFirst(m3uHeader.count)))

        return PlaylistBuilder(
            tvgURL: attributes["url-tvg"],
            imageURL: attributes["url-img"],
            xTvgURL: attributes["x-tvg-url"],
            tvgLogo: attributes["tvg-logo"]
        )
    }

    private static func buildStream(from line: String) -> PendingStream {
        let body = String(line.dropFirst(streamInfoHeader.count))
        let (metadata, title) = splitMetadataAndTitle(in: body)
        let attributes = parseAttributes(in: metadata)

        return PendingStream(
            title: title,
            tvgLogo: attributes["tvg-logo"],
            tvgID: attributes["tvg-id"],
            tvgName: attributes["tvg-name"],
            groupTitle: attributes["group-title"]
        )
    }

    private static func splitMetadataAndTitle(in line: String) -> (metadata: String, title: String) {
        var isInsideQuotes = false

        // Commas inside quoted attributes are part of metadata, not the title separator.
        for index in line.indices {
            let character = line[index]

            if character == "\"" {
                isInsideQuotes.toggle()
                continue
            }

            if character == ",", !isInsideQuotes {
                let metadata = String(line[..<index]).trimmingCharacters(in: .whitespaces)
                let titleStart = line.index(after: index)
                let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)

                return (metadata, title)
            }
        }

        return (line.trimmingCharacters(in: .whitespaces), "")
    }

    private static func parseAttributes(in line: String) -> [String: String] {
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        var attributes: [String: String] = [:]

        for match in attributeRegex.matches(in: line, range: nsRange) {
            guard
                let keyRange = Range(match.range(at: 1), in: line)
            else {
                continue
            }

            let key = String(line[keyRange])
            let valueRange = Range(match.range(at: 3), in: line)
                ?? Range(match.range(at: 4), in: line)

            guard let valueRange else {
                continue
            }

            attributes[key.lowercased()] = String(line[valueRange])
        }

        return attributes
    }
}
