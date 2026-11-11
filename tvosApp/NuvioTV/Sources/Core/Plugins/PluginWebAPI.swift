import Foundation

/// The JSON API behind the "Set Up from a Computer" page. Everything goes
/// through the same `PluginStore` as the TV screens, so a change on the web
/// shows on the TV at once (and repository changes sync to the account).
@MainActor
enum PluginWebAPI {
    typealias Request = PluginHTTPServerCore.Request
    typealias Response = PluginHTTPServerCore.Response

    static func handle(_ request: Request) async -> Response {
        // A provider's own configuration page ("Configure").
        if request.path.hasPrefix("/plugin/") {
            return await PluginRoutes.handleSetupPage(request)
        }
        // Only the setup page sends this header; a page elsewhere (a plugin's
        // sandboxed page included) can't, without a CORS answer it never gets.
        if request.method == "POST", request.headers["x-nuvio"] != "1" {
            return .error("Forbidden", status: 403)
        }
        let store = PluginStore.shared
        store.ensureLoaded()
        let body = request.json
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return Response(status: 200, contentType: "text/html; charset=utf-8", body: Data(PluginWebPage.html.utf8))

        case ("GET", "/api/state"):
            return .json(state())

        case ("POST", "/api/plugins-enabled"):
            store.setPluginsEnabled((body["enabled"] as? Bool) ?? true)
            return .json(state())

        case ("POST", "/api/auto-update"):
            store.setAutoUpdates((body["enabled"] as? Bool) ?? true)
            return .json(state())

        case ("POST", "/api/scrapers/code"):
            guard let id = body["id"] as? String, let code = body["code"] as? String else {
                return .error("Missing provider or code")
            }
            do {
                try store.uploadCode(code, scraperID: id)
                return .json(state())
            } catch {
                return .error(error.localizedDescription)
            }

        case ("POST", "/api/scrapers/code/revert"):
            guard let id = body["id"] as? String else { return .error("Missing provider") }
            store.revertUploadedCode(id)
            return .json(state())

        case ("POST", "/api/repositories/add"):
            guard let url = body["url"] as? String, !url.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .error("Enter the address of a plugin manifest.json.")
            }
            do {
                let repository = try await store.addRepository(url)
                var result = state()
                result["added"] = repository.name
                return .json(result)
            } catch {
                return .error(error.localizedDescription)
            }

        case ("POST", "/api/repositories/update"):
            guard let url = body["url"] as? String else { return .error("Missing repository") }
            await store.refreshRepository(url)
            return .json(state())

        case ("POST", "/api/repositories/remove"):
            guard let url = body["url"] as? String else { return .error("Missing repository") }
            store.removeRepository(url)
            return .json(state())

        case ("POST", "/api/repositories/move"):
            guard let url = body["url"] as? String else { return .error("Missing repository") }
            store.moveRepository(url, up: (body["up"] as? Bool) ?? true)
            return .json(state())

        case ("POST", "/api/repositories/developer"):
            guard let url = body["url"] as? String else { return .error("Missing repository") }
            store.setAlwaysReload(url, enabled: (body["enabled"] as? Bool) ?? false)
            return .json(state())

        case ("POST", "/api/scrapers/enabled"):
            guard let id = body["id"] as? String else { return .error("Missing provider") }
            store.setScraperEnabled(id, enabled: (body["enabled"] as? Bool) ?? true)
            return .json(state())

        case ("GET", "/api/scrapers/settings"):
            guard let scraper = store.scraper(id: request.query["id"] ?? "") else { return .error("Unknown provider", status: 404) }
            do {
                let fields = try await PluginSettingsService.layout(for: scraper)
                let saved = PluginSettingsVault.settings(scraperID: scraper.id)
                let code = await store.code(for: scraper) ?? ""
                return .json([
                    "ok": true,
                    "fields": fields.map(fieldJSON),
                    "values": PluginSettingsService.formValues(fields: fields, saved: saved),
                    "saved": PluginSettingsService.passwordHints(fields: fields, saved: saved),
                    "canVerify": PluginSettingsService.hasVerify(code: code)
                ])
            } catch {
                return .error(error.localizedDescription)
            }

        case ("POST", "/api/scrapers/settings"), ("POST", "/api/scrapers/verify"):
            guard let id = body["id"] as? String, let scraper = store.scraper(id: id) else {
                return .error("Unknown provider", status: 404)
            }
            let input = (body["values"] as? [String: Any]) ?? [:]
            let fields = (try? await PluginSettingsService.layout(for: scraper)) ?? []
            let saved = PluginSettingsVault.settings(scraperID: scraper.id)
            let merged = PluginSettingsService.merged(fields: fields, input: input, saved: saved)
            if request.path.hasSuffix("/verify") {
                guard let result = await PluginSettingsService.verify(scraper: scraper, settings: merged) else {
                    return .json(["ok": false, "message": "This provider cannot check its settings."])
                }
                return .json(["ok": result.ok, "message": result.message])
            }
            guard PluginSettingsVault.save(merged, scraperID: scraper.id) else {
                return .error("The settings could not be saved.")
            }
            return .json([
                "ok": true,
                "values": PluginSettingsService.formValues(fields: fields, saved: merged),
                "saved": PluginSettingsService.passwordHints(fields: fields, saved: merged)
            ])

        case ("GET", "/api/scrapers/logs"):
            let id = request.query["id"] ?? ""
            let formatter = ISO8601DateFormatter()
            let entries = PluginLogStore.shared.entries(for: id).map { entry in
                ["time": formatter.string(from: entry.date), "level": entry.level.rawValue, "message": entry.message]
            }
            return .json(["ok": true, "entries": entries])

        case ("POST", "/api/scrapers/logs/clear"):
            PluginLogStore.shared.clear((body["id"] as? String) ?? "")
            return .json(["ok": true])

        case ("POST", "/api/scrapers/test"):
            guard let id = body["id"] as? String, let scraper = store.scraper(id: id) else {
                return .error("Unknown provider", status: 404)
            }
            let type = (body["type"] as? String) == "movie" ? "movie" : "series"
            var sample = type == "movie" ? PluginTester.Sample.movie : PluginTester.Sample.episode
            if let imdb = (body["imdbId"] as? String)?.trimmingCharacters(in: .whitespaces), imdb.hasPrefix("tt") {
                sample.imdbID = imdb
            }
            if type != "movie" {
                sample.season = (body["season"] as? Int) ?? sample.season
                sample.episode = (body["episode"] as? Int) ?? sample.episode
            }
            let report = await PluginTester.run(scraper, sample: sample)
            return .json([
                "ok": !report.failed,
                "summary": report.summary,
                "sample": report.sample.label,
                "error": report.error.map { $0 as Any } ?? NSNull(),
                "streams": report.streams.prefix(50).map { stream in
                    [
                        "name": stream.name ?? "",
                        "description": stream.description ?? "",
                        "kind": streamKind(stream)
                    ]
                },
                "sections": report.sections.map { section -> [String: Any] in
                    [
                        "title": section.title,
                        "summary": section.summary,
                        "lines": section.lines,
                        "error": section.error.map { $0 as Any } ?? NSNull()
                    ]
                },
                "subtitles": report.subtitles.prefix(100).map { subtitle in
                    [
                        "language": subtitle.language,
                        "label": subtitle.label ?? "",
                        "url": subtitle.url
                    ]
                },
                "log": report.log.map { ["level": $0.level.rawValue, "message": $0.message] }
            ])

        default:
            return Response(status: 404, contentType: "application/json; charset=utf-8", body: Data(#"{"ok":false,"error":"Not found"}"#.utf8))
        }
    }

    private static func state() -> [String: Any] {
        let store = PluginStore.shared
        let formatter = ISO8601DateFormatter()
        return [
            "ok": true,
            "pluginsEnabled": store.state.pluginsEnabled,
            "autoUpdate": store.autoUpdates,
            "repositories": store.state.repositories.map { repository -> [String: Any] in
                [
                    "url": repository.manifestURL,
                    "name": repository.name,
                    "version": repository.version ?? "",
                    "author": repository.author ?? "",
                    "description": repository.description ?? "",
                    "error": repository.errorMessage ?? "",
                    "updated": repository.lastUpdated.map { formatter.string(from: $0) } ?? "",
                    "developer": repository.alwaysReload == true,
                    "updating": store.refreshing.contains(repository.manifestURL),
                    "scrapers": store.state.scrapers.filter { $0.repositoryURL == repository.manifestURL }.map { scraper -> [String: Any] in
                        [
                            "id": scraper.id,
                            "name": scraper.name,
                            "version": scraper.version,
                            "description": scraper.description,
                            "types": scraper.supportedTypes,
                            "languages": scraper.contentLanguage,
                            "enabled": scraper.enabled,
                            "manifestEnabled": scraper.manifestEnabled,
                            "hasSettings": scraper.hasSettings,
                            "resources": scraper.resources ?? [PluginResources.stream],
                            "logo": scraper.logo ?? "",
                            "configPage": scraper.configPage == true ? "plugin/\(PluginAddonRegistry.key(for: scraper.id))/" : "",
                            "uploadedCode": scraper.uploadedCode == true,
                            "keepAlive": scraper.keepAlive == true
                        ]
                    }
                ]
            }
        ]
    }

    private static func fieldJSON(_ field: PluginSettingField) -> [String: Any] {
        var object: [String: Any] = ["key": field.key, "label": field.label, "description": field.description ?? ""]
        switch field.kind {
        case .text(let isPassword, let placeholder):
            object["type"] = isPassword ? "password" : "text"
            object["placeholder"] = placeholder ?? ""
        case .select(let options):
            object["type"] = "select"
            object["options"] = options.map { ["label": $0.label, "value": $0.value] }
        case .toggle:
            object["type"] = "toggle"
        case .info:
            object["type"] = "info"
        }
        return object
    }

    private static func streamKind(_ stream: NuvioStream) -> String {
        guard let url = stream.url else { return stream.infoHash == nil ? "other" : "torrent" }
        if url.hasPrefix(UsenetStreamSpec.scheme + ":") { return "usenet" }
        if url.hasPrefix("magnet:") || stream.infoHash != nil { return "torrent" }
        return "http"
    }
}

extension PluginSettingsService {
    /// Values to show in a settings form: saved ones (or defaults), with
    /// passwords left empty — they never leave the Apple TV in full.
    static func formValues(fields: [PluginSettingField], saved: [String: Any]) -> [String: Any] {
        var values: [String: Any] = [:]
        for field in fields where !field.key.isEmpty {
            switch field.kind {
            case .text(let isPassword, _):
                values[field.key] = isPassword ? "" : (saved[field.key].flatMap(PluginJSON.text) ?? field.defaultText ?? "")
            case .select(let options):
                values[field.key] = saved[field.key].flatMap(PluginJSON.text) ?? field.defaultText ?? options.first?.value ?? ""
            case .toggle:
                if let value = saved[field.key], PluginJSON.isBoolean(value) {
                    values[field.key] = (value as? Bool) ?? false
                } else {
                    values[field.key] = field.defaultBool ?? false
                }
            case .info:
                break
            }
        }
        return values
    }

    /// `••••` plus the last four characters of each saved password.
    static func passwordHints(fields: [PluginSettingField], saved: [String: Any]) -> [String: String] {
        var hints: [String: String] = [:]
        for field in fields {
            guard case .text(true, _) = field.kind,
                  let value = saved[field.key].flatMap(PluginJSON.text), !value.isEmpty else { continue }
            hints[field.key] = "••••" + String(value.suffix(4))
        }
        return hints
    }

    /// The saved settings updated with form input. An empty password keeps
    /// the saved one; `"__clear__"` removes it. Keys the form doesn't know
    /// are left as they were.
    static func merged(fields: [PluginSettingField], input: [String: Any], saved: [String: Any]) -> [String: Any] {
        var result = saved
        for field in fields where !field.key.isEmpty {
            guard let value = input[field.key] else { continue }
            switch field.kind {
            case .text(let isPassword, _):
                let text = (PluginJSON.text(value) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if isPassword {
                    if text == "__clear__" { result[field.key] = nil } else if !text.isEmpty { result[field.key] = text }
                } else {
                    result[field.key] = text
                }
            case .select:
                result[field.key] = PluginJSON.text(value) ?? ""
            case .toggle:
                result[field.key] = PluginJSON.isBoolean(value) ? ((value as? Bool) ?? false) : (PluginJSON.text(value) == "true")
            case .info:
                break
            }
        }
        return result
    }
}
