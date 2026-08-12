import Foundation

/// TorBox cloud library: lists saved torrents, usenet and web downloads, then
/// requests a direct link per file at play time. Ported from the Android
/// `TorboxCloudLibraryProviderApi`.
struct TorboxCloudLibrary: CloudLibraryProvider {
    let providerId = "torbox"
    let displayName = "TorBox"

    private let base = URL(string: "https://api.torbox.app")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listItems(apiKey: String) async throws -> [CloudItem] {
        // Each list is independent; a failure in one shouldn't sink the others.
        async let torrents = fetch("v1/api/torrents/mylist", type: .torrent, apiKey: apiKey)
        async let usenet = fetch("v1/api/usenet/mylist", type: .usenet, apiKey: apiKey)
        async let web = fetch("v1/api/webdl/mylist", type: .webDownload, apiKey: apiKey)
        return try await torrents + usenet + web
    }

    func resolvePlayback(apiKey: String, item: CloudItem, file: CloudFile) async -> CloudPlaybackResult {
        guard file.playable else { return .notPlayable }
        let (path, idParam): (String, String) = {
            switch item.type {
            case .torrent: return ("v1/api/torrents/requestdl", "torrent_id")
            case .usenet: return ("v1/api/usenet/requestdl", "usenet_id")
            case .webDownload: return ("v1/api/webdl/requestdl", "web_id")
            case .file: return ("v1/api/torrents/requestdl", "torrent_id")
            }
        }()

        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: idParam, value: item.id),
            URLQueryItem(name: "file_id", value: file.id),
            URLQueryItem(name: "zip_link", value: "false"),
            URLQueryItem(name: "redirect", value: "false"),
            URLQueryItem(name: "append_name", value: "false")
        ]
        guard let url = components?.url else { return .failed(nil) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return .failed(nil)
            }
            let envelope = try JSONDecoder().decode(Envelope<String>.self, from: data)
            guard envelope.success != false, let link = envelope.data, !link.isEmpty, let resolved = URL(string: link) else {
                return .failed(envelope.detail ?? envelope.error)
            }
            return .success(url: resolved, filename: file.name, videoSize: file.sizeBytes)
        } catch is CancellationError {
            return .failed(nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Listing

    private func fetch(_ path: String, type: CloudItemType, apiKey: String) async throws -> [CloudItem] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudLibraryError.request
        }
        let envelope = try JSONDecoder().decode(Envelope<[Item]>.self, from: data)
        guard envelope.success != false else { throw CloudLibraryError.request }
        return (envelope.data ?? []).compactMap { $0.toCloudItem(providerId: providerId, type: type) }
    }
}

// MARK: - TorBox DTOs

/// Decodes an `id` field that TorBox returns as either a number or a string.
private struct FlexibleID: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = String(int) }
        else if let string = try? container.decode(String.self) { value = string }
        else { value = nil }
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let success: Bool?
    let data: T?
    let error: String?
    let detail: String?
}

private struct Item: Decodable {
    let id: FlexibleID?
    let hash: String?
    let name: String?
    let status: String?
    let size: Int64?
    let totalSize: Int64?
    let files: [File]?

    enum CodingKeys: String, CodingKey {
        case id, hash, name, status, size, files
        case totalSize = "total_size"
    }

    func toCloudItem(providerId: String, type: CloudItemType) -> CloudItem? {
        guard let itemId = id?.value?.nonEmpty ?? hash?.nonEmpty else { return nil }
        let itemName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? itemId
        let cloudFiles = (files ?? []).compactMap { $0.toCloudFile() }
        let filesSize = cloudFiles.compactMap(\.sizeBytes)
        return CloudItem(
            providerId: providerId, id: itemId, type: type, name: itemName, status: status,
            sizeBytes: size ?? totalSize ?? (filesSize.isEmpty ? nil : filesSize.reduce(0, +)),
            files: cloudFiles
        )
    }

    struct File: Decodable {
        let id: FlexibleID?
        let name: String?
        let shortName: String?
        let size: Int64?
        let mimeType: String?

        enum CodingKeys: String, CodingKey {
            case id, name, size
            case shortName = "short_name"
            case mimeType = "mimetype"
        }

        func toCloudFile() -> CloudFile? {
            let display = shortName?.nonEmpty
                ?? name?.split(separator: "/").last.map(String.init)
                ?? name?.nonEmpty
            guard let display, let fileId = id?.value?.nonEmpty else { return nil }
            let playable = mimeType?.lowercased().hasPrefix("video/") == true || DebridVideo.isPlayable(display)
            return CloudFile(id: fileId, name: display, sizeBytes: size, mimeType: mimeType, playable: playable, playbackUrl: nil)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
