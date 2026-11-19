import Foundation

actor SceneSubtitleTimelineScraper {
    private let urlSession: URLSession
    private var isScraping: Bool = false
    private var scrapedCanonicalId: String?
    
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init(urlSession: URLSession = defaultSession) {
        self.urlSession = urlSession
    }
    
    func reset() {
        isScraping = false
        scrapedCanonicalId = nil
    }
    
    /// Scrapes candidate subtitles in the background, looking for one with speaker cues (SDH / CC),
    /// parses them into exact scene timeline intervals, and stores them in the result cache.
    func scrapeNamedSubtitleTimeline(
        subtitles: [NuvioSubtitle],
        candidates: [SceneCastCandidate],
        context: SceneContext,
        resultCache: SceneResultCache
    ) async {
        guard !subtitles.isEmpty else { return }
        guard !isScraping, scrapedCanonicalId != context.canonicalId else { return }
        
        isScraping = true
        defer { isScraping = false }
        
        let prioritized = prioritizeSubtitles(subtitles)
        print("[SceneScraper] Prioritized \(prioritized.count) subtitle candidate(s) to inspect for \"\(context.title)\"")
        
        var combinedIntervals: [SceneTimelineInterval] = []
        var foundMusicCues = false
        var foundSpeakerCues = false
        
        // Inspect up to 2 candidate subtitle tracks to get timeline intervals without congesting network
        let inspectionLimit = min(prioritized.count, 2)
        for i in 0..<inspectionLimit {
            let sub = prioritized[i]
            guard let url = URL(string: sub.url) else { continue }
            
            do {
                let (data, response) = try await urlSession.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                
                guard let content = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? String(data: data, encoding: .windowsCP1252) else { continue }
                
                let intervals = parseSubtitleTimeline(
                    content: content,
                    candidates: candidates,
                    context: context
                )
                
                if !intervals.isEmpty {
                    for interval in intervals {
                        if interval.song != nil {
                            foundMusicCues = true
                            combinedIntervals.append(interval)
                        } else if !interval.actors.isEmpty {
                            foundSpeakerCues = true
                            combinedIntervals.append(interval)
                        }
                    }
                }
                
                // If we found both speaker cues and music cues, we have a complete timeline
                if foundSpeakerCues && foundMusicCues {
                    break
                }
            } catch {
                print("[SceneScraper] Subtitle fetch failed for \(AddonTransportUrls.diagnosticDescription(for: url)): \(error.localizedDescription)")
            }
        }
        
        if !combinedIntervals.isEmpty {
            print("[SceneScraper] Successfully extracted \(combinedIntervals.count) timeline intervals (music: \(foundMusicCues), speakers: \(foundSpeakerCues)) for \"\(context.title)\"")
            await resultCache.storeTimelineIntervals(combinedIntervals)
            scrapedCanonicalId = context.canonicalId
        }
    }
    
    /// Prioritizes English and SDH / CC tracks first.
    func prioritizeSubtitles(_ subtitles: [NuvioSubtitle]) -> [NuvioSubtitle] {
        subtitles.sorted { a, b in
            let aScore = subtitleScore(a)
            let bScore = subtitleScore(b)
            return aScore > bScore
        }
    }
    
    private func subtitleScore(_ sub: NuvioSubtitle) -> Int {
        var score = 0
        let lang = sub.language.lowercased()
        let label = (sub.label ?? "").lowercased()
        let url = sub.url.lowercased()
        
        if lang.hasPrefix("en") || lang == "eng" || lang == "english" {
            score += 10
        }
        if label.contains("sdh") || url.contains("sdh") {
            score += 20
        }
        if label.contains("cc") || url.contains("cc") {
            score += 15
        }
        if label.contains("hearing") || label.contains("impaired") {
            score += 20
        }
        return score
    }
    
    func parseSubtitleTimeline(
        content: String,
        candidates: [SceneCastCandidate],
        context: SceneContext
    ) -> [SceneTimelineInterval] {
        let cues = parseSRTOrVTT(content)
        guard !cues.isEmpty else { return [] }
        
        var intervals: [SceneTimelineInterval] = []
        for cue in cues {
            let speakers = SceneSubtitleSpeakerRecognizer.detectSpeakers(
                in: cue.text,
                candidates: candidates
            )
            let song = SceneSubtitleMusicRecognizer.detectSong(
                in: cue.text,
                startTime: cue.start,
                endTime: cue.end,
                canonicalId: context.canonicalId
            )
            guard !speakers.isEmpty || song != nil else { continue }
            
            let actors = speakers.map { candidate in
                SceneRecognizedActor(
                    id: candidate.id,
                    name: candidate.name,
                    character: candidate.character,
                    profileURL: candidate.profileURL,
                    confidence: 0.98,
                    tmdbId: candidate.tmdbId ?? Int(candidate.id)
                )
            }
            
            let interval = SceneTimelineInterval(
                id: "sub-\(UUID().uuidString)",
                canonicalId: context.canonicalId,
                season: context.season,
                episode: context.episode,
                startTime: cue.start,
                endTime: cue.end,
                actors: actors,
                song: song,
                sceneDescription: song?.sceneDescription
            )
            intervals.append(interval)
        }
        return intervals
    }
    
    struct SubtitleCueParsed: Sendable {
        let start: Double
        let end: Double
        let text: String
    }
    
    func parseSRTOrVTT(_ content: String) -> [SubtitleCueParsed] {
        var cues: [SubtitleCueParsed] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2,
                   let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                   let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces)) {
                    var textLines: [String] = []
                    i += 1
                    while i < lines.count {
                        let textLine = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        if textLine.isEmpty { break }
                        if textLine.contains("-->") {
                            i -= 1
                            break
                        }
                        textLines.append(textLine)
                        i += 1
                    }
                    let fullText = textLines.joined(separator: "\n")
                    if !fullText.isEmpty {
                        cues.append(SubtitleCueParsed(start: start, end: end, text: fullText))
                    }
                }
            }
            i += 1
        }
        return cues
    }
    
    private func parseTimestamp(_ raw: String) -> Double? {
        let cleanRaw = raw.components(separatedBy: .whitespaces).first ?? raw
        let normalized = cleanRaw.replacingOccurrences(of: ",", with: ".")
        let components = normalized.components(separatedBy: ":")
        guard !components.isEmpty else { return nil }
        if components.count == 3 {
            guard let h = Double(components[0]),
                  let m = Double(components[1]),
                  let s = Double(components[2]) else { return nil }
            return h * 3600.0 + m * 60.0 + s
        } else if components.count == 2 {
            guard let m = Double(components[0]),
                  let s = Double(components[1]) else { return nil }
            return m * 60.0 + s
        } else {
            return Double(normalized)
        }
    }
}
