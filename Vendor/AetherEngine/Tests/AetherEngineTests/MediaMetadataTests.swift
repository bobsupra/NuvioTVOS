import Testing
import Foundation
@testable import AetherEngine

@Suite("MediaMetadata normalization")
struct MediaMetadataTests {

    @Test("Empty and whitespace strings normalize to nil")
    func emptyBecomesNil() {
        let m = MediaMetadata.from(title: "  ", artist: "", album: nil,
                                   albumArtist: nil, artworkData: nil)
        #expect(m.title == nil)
        #expect(m.artist == nil)
        #expect(m.album == nil)
        #expect(m.artworkData == nil)
    }

    @Test("album_artist fills in when artist is missing")
    func albumArtistFallback() {
        let m = MediaMetadata.from(title: "Song", artist: nil, album: "LP",
                                   albumArtist: "The Band", artworkData: nil)
        #expect(m.artist == "The Band")
    }

    @Test("artist wins over album_artist when both present")
    func artistWins() {
        let m = MediaMetadata.from(title: nil, artist: "Soloist", album: nil,
                                   albumArtist: "The Band", artworkData: nil)
        #expect(m.artist == "Soloist")
    }

    @Test("Values are trimmed and artwork passes through")
    func trimsAndKeepsArtwork() {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let m = MediaMetadata.from(title: "  Hi ", artist: "A", album: "B",
                                   albumArtist: nil, artworkData: bytes)
        #expect(m.title == "Hi")
        #expect(m.artworkData == bytes)
    }

    @Test("Whitespace-only albumArtist does not become artist")
    func whitespaceAlbumArtistIsNil() {
        let m = MediaMetadata.from(title: "S", artist: nil, album: nil,
                                   albumArtist: "   ", artworkData: nil)
        #expect(m.artist == nil)
    }

    @Test("hasDisplayMetadata is false when all text fields are empty")
    func hasDisplayMetadataFlag() {
        let empty = MediaMetadata.from(title: nil, artist: nil, album: nil,
                                       albumArtist: nil, artworkData: nil)
        #expect(empty.hasDisplayMetadata == false)
        let some = MediaMetadata.from(title: "X", artist: nil, album: nil,
                                      albumArtist: nil, artworkData: nil)
        #expect(some.hasDisplayMetadata == true)
    }
}
