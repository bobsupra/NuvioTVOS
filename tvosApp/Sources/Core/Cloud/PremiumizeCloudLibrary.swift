import Foundation

/// Premiumize cloud library: `item/listall` returns every saved file with a
/// direct link, so most files play without a second call. Files are grouped by
/// their top-level folder (season packs, etc.). Ported from the Android
/// `PremiumizeCloudLibraryProviderApi`.
struct PremiumizeCloudLibrary: CloudLibraryProvider {
    let providerId = "premiumize"
    let displayName = "Premiumize"

    private let base = URL(string: "https://www.premiumize.me")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listItems(apiKey: String) async throws -> [CloudItem] {
        var req = URLRequest(url: base.appendingPathComponent("api/item/listall"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudLibraryError.request
        }
        let decoded = try JSONDecoder().decode(ListAll.self, from: data)
        guard decoded.status?.lowercased() != "error" else { throw CloudLibraryError.request }
        return Self.group(files: decoded.files ?? [], providerId: providerId)
    }

    func resolvePlayback(apiKey: String, item: CloudItem, file: CloudFile) async -> CloudPlaybackResult {
        guard file.playable else { return .notPlayable }
        // Premiumize usually hands us the link up front.
        if let direct = file.playbackUrl, !direct.isEmpty, let url = URL(string: direct) {
            return .success(url: url, filename: file.name, videoSize: file.sizeBytes)
        }
        // Fall back to item/details for a fresh link.
        var components = URLComponents(url: base.appendingPathComponent("api/item/details"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: file.id)]
        guard let url = components?.url else { return .failed(nil) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return .failed(nil)
            }
            let details = try JSONDecoder().decode(ItemDetails.self, from: data)
            guard details.status?.lowercased() != "error",
                  let link = details.link, !link.isEmpty, let resolved = URL(string: link) else {
                return .failed(details.message)
            }
            return .success(url: resolved, filename: details.name ?? file.name, videoSize: details.size ?? file.sizeBytes)
        } catch is CancellationError {
            return .failed(nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Grouping

    /// Groups flat files into items by their top-level folder; root-level files
    /// each become their own single-file item.
    private static func group(files: [ListAll.File], providerId: String) -> [CloudItem] {
        struct Mapped { let groupKey, itemId, itemName: String; let file: CloudFile }

        let mapped: [Mapped] = files.compactMap { dto in
            let path = dto.path?.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            let fileName = dto.name?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? path?.split(separator: "/").last.map(String.init)
            guard let fileName, !fileName.isEmpty else { return nil }

            let playable = isPlayable(name: fileName, mime: dto.mimeType)
            let segments = (path?.split(separator: "/").map(String.init) ?? []).filter { !$0.isEmpty }
            let isRoot = segments.count <= 1
            let itemName = isRoot ? fileName : (segments.first ?? fileName)
            let itemId = isRoot ? "file:\(dto.id ?? path ?? fileName)" : "folder:\(segments.first ?? itemName)"

            return Mapped(
                groupKey: itemId, itemId: itemId, itemName: itemName,
                file: CloudFile(
                    id: dto.id ?? fileName, name: fileName, sizeBytes: dto.size,
                    mimeType: dto.mimeType, playable: playable,
                    playbackUrl: playable ? dto.link?.nonEmpty : nil
                )
            )
        }

        let groups = Dictionary(grouping: mapped, by: \.groupKey)
        return groups.values.compactMap { group -> CloudItem? in
            guard let first = group.first else { return nil }
            let cloudFiles = group.map(\.file).sorted {
                ($0.playable ? 0 : 1, $0.name.lowercased()) < ($1.playable ? 0 : 1, $1.name.lowercased())
            }
            let size = cloudFiles.compactMap(\.sizeBytes)
            return CloudItem(
                providerId: providerId, id: first.itemId, type: .file, name: first.itemName,
                status: "Ready", sizeBytes: size.isEmpty ? nil : size.reduce(0, +), files: cloudFiles
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func isPlayable(name: String, mime: String?) -> Bool {
        if mime?.lowercased().hasPrefix("video/") == true { return true }
        return DebridVideo.isPlayable(name)
    }
}

enum CloudLibraryError: Error { case request }

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Premiumize DTOs

private struct ListAll: Decodable {
    let status: String?
    let files: [File]?

    struct File: Decodable {
        let id: String?
        let name: String?
        let path: String?
        let size: Int64?
        let link: String?
        let mimeType: String?

        enum CodingKeys: String, CodingKey {
            case id, name, path, size, link
            case mimeType = "mime_type"
        }
    }
}

private struct ItemDetails: Decodable {
    let status: String?
    let message: String?
    let name: String?
    let size: Int64?
    let link: String?
}
