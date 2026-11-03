import Foundation
import CoreGraphics
import AVFoundation

// MARK: - Scene Tab

enum SceneTab: String, CaseIterable, Identifiable, Sendable {
    case chapters = "Chapters"
    case autoSync = "AutoSubSync"
    case info = "Info"
    case scene = "Scene"
    case upNext = "Up Next"
    case watchParty = "Watch Party"

    var id: String { rawValue }

    var localizedTitle: String {
        let isNorwegian = Locale.preferredLanguages.first?.hasPrefix("nb") == true || Locale.preferredLanguages.first?.hasPrefix("no") == true
        switch self {
        case .chapters:
            return L10n.string("player_chapters", fallback: "Chapters")
        case .autoSync:
            return L10n.string("player_autosync_tab", fallback: "AutoSubSync")
        case .info:
            return "Info"
        case .scene:
            return isNorwegian ? "Innblikk" : "InSight"
        case .upNext:
            return isNorwegian ? "Fortsett å se" : "Up Next"
        case .watchParty:
            return isNorwegian ? "Se sammen" : "Watch Party"
        }
    }
}

// MARK: - Scene Playback Info

struct ScenePlaybackInfo: Equatable, Sendable {
    // PLAYBACK ENGINE
    var engine: String
    var version: String
    
    // VIDEO STREAM
    var videoCodec: String
    var resolution: String
    var frameRate: String
    var dynamicRange: String
    var dolbyVisionProfile: String?
    var videoBitrate: String
    var container: String
    var videoDecoder: String
    
    // AUDIO STREAM
    var audioCodec: String
    var audioChannels: String
    var audioLanguage: String
    var audioBitrate: String
    var audioSpatialFormat: String
    var audioDecoder: String
    var avSyncGapMs: Double?
    
    init(
        engine: String = "—",
        version: String = "—",
        videoCodec: String = "—",
        resolution: String = "—",
        frameRate: String = "—",
        dynamicRange: String = "—",
        dolbyVisionProfile: String? = nil,
        videoBitrate: String = "—",
        container: String = "—",
        videoDecoder: String = "—",
        audioCodec: String = "—",
        audioChannels: String = "—",
        audioLanguage: String = "—",
        audioBitrate: String = "—",
        audioSpatialFormat: String = "Not confirmed",
        audioDecoder: String = "Unavailable",
        avSyncGapMs: Double? = nil
    ) {
        self.engine = engine
        self.version = version
        self.videoCodec = videoCodec
        self.resolution = resolution
        self.frameRate = frameRate
        self.dynamicRange = dynamicRange
        self.dolbyVisionProfile = dolbyVisionProfile
        self.videoBitrate = videoBitrate
        self.container = container
        self.videoDecoder = videoDecoder
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioLanguage = audioLanguage
        self.audioBitrate = audioBitrate
        self.audioSpatialFormat = audioSpatialFormat
        self.audioDecoder = audioDecoder
        self.avSyncGapMs = avSyncGapMs
    }
}

// MARK: - Scene Context

struct SceneContext: Equatable, Sendable {
    let canonicalId: String
    let mediaType: String
    let title: String
    let season: Int?
    let episode: Int?
    let tmdbId: Int?
    let imdbId: String?
    let streamURL: URL?
    let sessionID: UUID
    let timelineGeneration: UInt64
    let selectedAudioTrackId: Int?
    let isLiveStream: Bool
    let backend: PlayerBackendKind
    let isAnime: Bool

    init(
        canonicalId: String,
        mediaType: String,
        title: String,
        season: Int? = nil,
        episode: Int? = nil,
        tmdbId: Int? = nil,
        imdbId: String? = nil,
        streamURL: URL? = nil,
        sessionID: UUID = UUID(),
        timelineGeneration: UInt64 = 0,
        selectedAudioTrackId: Int? = nil,
        isLiveStream: Bool = false,
        backend: PlayerBackendKind = .aether,
        isAnime: Bool = false
    ) {
        self.canonicalId = canonicalId
        self.mediaType = mediaType
        self.title = title
        self.season = season
        self.episode = episode
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.streamURL = streamURL
        self.sessionID = sessionID
        self.timelineGeneration = timelineGeneration
        self.selectedAudioTrackId = selectedAudioTrackId
        self.isLiveStream = isLiveStream
        self.backend = backend
        self.isAnime = isAnime
    }
}

// MARK: - Scene Frame

struct SceneFrame: @unchecked Sendable {
    let image: CGImage
    let sourceTime: Double
    let sessionID: UUID
    let generation: UInt64
    let pixelSize: CGSize
    let captureDiagnostics: String?

    init(
        image: CGImage,
        sourceTime: Double,
        sessionID: UUID,
        generation: UInt64,
        captureDiagnostics: String? = nil
    ) {
        self.image = image
        self.sourceTime = sourceTime
        self.sessionID = sessionID
        self.generation = generation
        self.pixelSize = CGSize(width: image.width, height: image.height)
        self.captureDiagnostics = captureDiagnostics
    }
}

// MARK: - Recognized Actor

struct SceneRecognizedActor: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let character: String?
    let profileURL: URL?
    let confidence: Float
    let tmdbId: Int?

    init(
        id: String,
        name: String,
        character: String? = nil,
        profileURL: URL? = nil,
        confidence: Float = 1.0,
        tmdbId: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.character = character
        self.profileURL = profileURL
        self.confidence = confidence
        self.tmdbId = tmdbId
    }
}

// MARK: - Recognized Song

struct SceneRecognizedSong: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let appleMusicURL: URL?
    let shazamURL: URL?
    let genres: [String]
    let observedSourceTime: Double
    let startTime: Double?
    let endTime: Double?
    let sceneDescription: String?

    init(
        id: String,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        appleMusicURL: URL? = nil,
        shazamURL: URL? = nil,
        genres: [String] = [],
        observedSourceTime: Double = 0,
        startTime: Double? = nil,
        endTime: Double? = nil,
        sceneDescription: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.appleMusicURL = appleMusicURL
        self.shazamURL = shazamURL
        self.genres = genres
        self.observedSourceTime = observedSourceTime
        self.startTime = startTime
        self.endTime = endTime
        self.sceneDescription = sceneDescription
    }

    /// Determines if this song should be actively visible at the specified video timestamp.
    func isActive(at sourceTime: Double) -> Bool {
        if let startTime, let endTime {
            return sourceTime >= startTime && sourceTime <= endTime
        }
        if let startTime {
            return sourceTime >= startTime && sourceTime <= (startTime + 45.0)
        }
        return abs(sourceTime - observedSourceTime) <= 30.0
    }
}

// MARK: - Scene Timeline Interval (Database & Cache)

struct SceneTimelineInterval: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let canonicalId: String
    let season: Int?
    let episode: Int?
    let startTime: Double
    let endTime: Double
    let actors: [SceneRecognizedActor]
    let song: SceneRecognizedSong?
    let sceneDescription: String?

    init(
        id: String = UUID().uuidString,
        canonicalId: String,
        season: Int? = nil,
        episode: Int? = nil,
        startTime: Double,
        endTime: Double,
        actors: [SceneRecognizedActor],
        song: SceneRecognizedSong? = nil,
        sceneDescription: String? = nil
    ) {
        self.id = id
        self.canonicalId = canonicalId
        self.season = season
        self.episode = episode
        self.startTime = startTime
        self.endTime = endTime
        self.actors = actors
        self.song = song
        self.sceneDescription = sceneDescription
    }

    func contains(timestamp: Double) -> Bool {
        timestamp >= startTime && timestamp <= endTime
    }
}

// MARK: - Independent Statuses

enum SceneActorStatus: Equatable, Sendable {
    case disabled
    case preparingReferences
    case analyzing
    case recognized([SceneRecognizedActor])
    case noMatch
    case unavailable(reason: String)
    case failed(reason: String)

    var isRecognized: Bool {
        if case .recognized(let actors) = self { return !actors.isEmpty }
        return false
    }

    var actors: [SceneRecognizedActor] {
        if case .recognized(let list) = self { return list }
        return []
    }
}

enum SceneMusicStatus: Equatable, Sendable {
    case disabled
    case listening
    case matched(SceneRecognizedSong)
    case noMatch
    case requiresPlayback
    case unavailable(reason: String)
    case failed(reason: String)

    var matchedSong: SceneRecognizedSong? {
        if case .matched(let song) = self { return song }
        return nil
    }
}

// MARK: - Scene Snapshot

struct SceneSnapshot: Equatable, Sendable {
    let timestamp: Double
    let actors: [SceneRecognizedActor]
    let song: SceneRecognizedSong?
    let actorStatus: SceneActorStatus
    let musicStatus: SceneMusicStatus
    let generation: UInt64

    init(
        timestamp: Double = 0,
        actors: [SceneRecognizedActor] = [],
        song: SceneRecognizedSong? = nil,
        actorStatus: SceneActorStatus = .disabled,
        musicStatus: SceneMusicStatus = .disabled,
        generation: UInt64 = 0
    ) {
        self.timestamp = timestamp
        self.actors = actors
        self.song = song
        self.actorStatus = actorStatus
        self.musicStatus = musicStatus
        self.generation = generation
    }

    static let empty = SceneSnapshot()
}

// MARK: - Person Media Credit & Full Detail

struct ScenePersonMediaCredit: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let tmdbId: Int
    let title: String
    let mediaType: String // "movie" or "tv"
    let posterURL: URL?
    let backdropURL: URL?
    let character: String?
    let releaseYear: String?
    let voteAverage: Double?

    init(
        id: String = UUID().uuidString,
        tmdbId: Int,
        title: String,
        mediaType: String,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        character: String? = nil,
        releaseYear: String? = nil,
        voteAverage: Double? = nil
    ) {
        self.id = id
        self.tmdbId = tmdbId
        self.title = title
        self.mediaType = mediaType
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.character = character
        self.releaseYear = releaseYear
        self.voteAverage = voteAverage
    }
    
    var asRelatedTitle: RelatedTitle {
        RelatedTitle(
            id: "tmdb:\(tmdbId)",
            type: mediaType == "tv" ? "series" : "movie",
            name: title,
            posterURL: posterURL?.absoluteString,
            year: releaseYear,
            rating: voteAverage,
            overview: nil,
            backdropURL: backdropURL?.absoluteString
        )
    }
}

struct ScenePersonDetail: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: Int
    let name: String
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let profileURL: URL?
    let movies: [ScenePersonMediaCredit]
    let series: [ScenePersonMediaCredit]

    init(
        id: Int,
        name: String,
        biography: String? = nil,
        birthday: String? = nil,
        deathday: String? = nil,
        placeOfBirth: String? = nil,
        profileURL: URL? = nil,
        movies: [ScenePersonMediaCredit] = [],
        series: [ScenePersonMediaCredit] = []
    ) {
        self.id = id
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.placeOfBirth = placeOfBirth
        self.profileURL = profileURL
        self.movies = movies
        self.series = series
    }
    
    /// Formatted birth string matching screenshot:
    /// e.g. "Born: Jul 28, 1974 (age 52)" or "Died: Jan 22, 2008 (aged 28)"
    var birthInfo: String? {
        guard let birthday, !birthday.isEmpty else { return nil }
        
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")
        inputFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        guard let birthDate = inputFormatter.date(from: birthday) else {
            return "Born: \(birthday)"
        }
        
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MMM d, yyyy"
        outputFormatter.locale = Locale(identifier: "en_US_POSIX")
        outputFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        let formattedBirth = outputFormatter.string(from: birthDate)
        
        let calendar = Calendar.current
        if let deathday, !deathday.isEmpty, let deathDate = inputFormatter.date(from: deathday) {
            let formattedDeath = outputFormatter.string(from: deathDate)
            let ageComponents = calendar.dateComponents([.year], from: birthDate, to: deathDate)
            if let age = ageComponents.year {
                return "Died: \(formattedDeath) (aged \(age)) • Born: \(formattedBirth)"
            } else {
                return "Died: \(formattedDeath) • Born: \(formattedBirth)"
            }
        } else {
            let ageComponents = calendar.dateComponents([.year], from: birthDate, to: Date())
            if let age = ageComponents.year {
                return "Born: \(formattedBirth) (age \(age))"
            } else {
                return "Born: \(formattedBirth)"
            }
        }
    }
}

// MARK: - Scene Detail Item

enum SceneDetailItem: Identifiable, Equatable, Sendable {
    case actor(SceneRecognizedActor, detail: ScenePersonDetail?)
    case song(SceneRecognizedSong)

    var id: String {
        switch self {
        case .actor(let actor, _): return "actor-\(actor.id)"
        case .song(let song): return "song-\(song.id)"
        }
    }
}

// MARK: - Cast Candidate (Reference metadata)

struct SceneCastCandidate: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let character: String?
    let profileURL: URL?
    let additionalImageURLs: [URL]
    let tmdbId: Int?
    let order: Int

    init(
        id: String,
        name: String,
        character: String? = nil,
        profileURL: URL? = nil,
        additionalImageURLs: [URL] = [],
        tmdbId: Int? = nil,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.character = character
        self.profileURL = profileURL
        self.additionalImageURLs = additionalImageURLs
        self.tmdbId = tmdbId
        self.order = order
    }
    
    var allImageURLs: [URL] {
        var list: [URL] = []
        if let profileURL {
            list.append(profileURL)
        }
        for url in additionalImageURLs {
            if !list.contains(url) {
                list.append(url)
            }
        }
        return list
    }
}
