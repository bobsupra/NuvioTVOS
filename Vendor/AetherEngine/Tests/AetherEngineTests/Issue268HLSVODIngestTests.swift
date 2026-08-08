import Foundation
import XCTest
@testable import AetherEngine

/// #268: HEVC carried in finite MPEG-TS HLS must be identified from the
/// playlist and PMT, then exposed through the seekable VOD ingest rather than
/// handed to AVPlayer's black native path.
final class Issue268HLSVODIngestTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Issue268URLProtocol.reset()
    }

    func testDirectMediaPlaylistBuildsSeekableHEVCReader() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/media.m3u8"))
        let segment = try XCTUnwrap(URL(string: "https://vod.test/segment.ts"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist("segment.ts")
        Issue268URLProtocol.bodyByURL[segment.absoluteString] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: ["X-Fixture": "allowed"],
            session: session
        )
        let admitted = try XCTUnwrap(reader)
        defer { admitted.close() }

        XCTAssertEqual(admitted.mediaDuration, 6, accuracy: 0.001)
        XCTAssertTrue(admitted.seek(to: 5))
        var bytes = [UInt8](repeating: 0, count: 188)
        let count = bytes.withUnsafeMutableBufferPointer {
            admitted.read($0.baseAddress, size: Int32($0.count))
        }
        XCTAssertEqual(count, 188)
        XCTAssertEqual(bytes[0], 0x47)
        XCTAssertEqual(
            Issue268URLProtocol.headersByURL[root.absoluteString]?["X-Fixture"],
            "allowed"
        )
        XCTAssertEqual(
            Issue268URLProtocol.headersByURL[segment.absoluteString]?["X-Fixture"],
            "allowed"
        )
    }

    func testMasterPlaylistUsesHighestBandwidthHEVCVariant() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/master.m3u8"))
        let low = try XCTUnwrap(URL(string: "https://vod.test/low.m3u8"))
        let high = try XCTUnwrap(URL(string: "https://vod.test/high.m3u8"))
        let lowSegment = try XCTUnwrap(URL(string: "https://vod.test/low.ts"))
        let highSegment = try XCTUnwrap(URL(string: "https://vod.test/high.ts"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000
        high.m3u8
        """.utf8)
        Issue268URLProtocol.bodyByURL[low.absoluteString] = mediaPlaylist("low.ts")
        Issue268URLProtocol.bodyByURL[high.absoluteString] = mediaPlaylist("high.ts")
        Issue268URLProtocol.bodyByURL[lowSegment.absoluteString] = transportStream(streamType: 0x1B)
        Issue268URLProtocol.bodyByURL[highSegment.absoluteString] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        XCTAssertNotNil(reader)
        reader?.close()
        XCTAssertNil(Issue268URLProtocol.headersByURL[low.absoluteString])
        XCTAssertNotNil(Issue268URLProtocol.headersByURL[high.absoluteString])
        XCTAssertNil(Issue268URLProtocol.headersByURL[lowSegment.absoluteString])
        XCTAssertNotNil(Issue268URLProtocol.headersByURL[highSegment.absoluteString])
    }

    func testH264MPEGTSRemainsOnNativeHLSRoute() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/h264.m3u8"))
        let segment = try XCTUnwrap(URL(string: "https://vod.test/h264.ts"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist("h264.ts")
        Issue268URLProtocol.bodyByURL[segment.absoluteString] = transportStream(streamType: 0x1B)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        XCTAssertNil(reader)
    }

    func testFMP4AndLivePlaylistsRemainOnExistingRoutes() async throws {
        let fmp4 = try XCTUnwrap(URL(string: "https://vod.test/fmp4.m3u8"))
        let live = try XCTUnwrap(URL(string: "https://vod.test/live.m3u8"))
        Issue268URLProtocol.bodyByURL[fmp4.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        segment.m4s
        #EXT-X-ENDLIST
        """.utf8)
        Issue268URLProtocol.bodyByURL[live.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        segment.ts
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fmp4Reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: fmp4,
            httpHeaders: [:],
            session: session
        )
        let liveReader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: live,
            httpHeaders: [:],
            session: session
        )
        XCTAssertNil(fmp4Reader)
        XCTAssertNil(liveReader)
    }

    func testUnreachableFirstSegmentKeepsTheNativeRoute() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/dead-segment.m3u8"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist("missing.ts")

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        XCTAssertNil(reader, "an unreachable probe is inconclusive, and inconclusive never reroutes")
    }

    // MARK: - Seek axis

    /// A seek restarts one segment ahead of the segment containing the target: playlists need not
    /// declare EXT-X-INDEPENDENT-SEGMENTS, so the extra segment guarantees a random-access point in
    /// front of the target. Landing early is the contract; the engine's packet gate trims the rest.
    func testRestartSegmentIndexStartsOneSegmentAheadOfTheTarget() {
        let starts: [Double] = [0, 6, 12, 18, 24]
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 20, starts: starts), 2)
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 12, starts: starts), 1)
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 6.001, starts: starts), 0)
    }

    /// A target sitting just below a segment start belongs to that segment. The plan built on this
    /// playlist backs each boundary off so an IRAP can never fall below its own boundary (AE#268);
    /// without the same tolerance here, every seek to such a boundary would refetch one segment more
    /// than it needs. The tolerance uses the plan's own formula, so it never reaches the previous start.
    func testRestartSegmentIndexSnapsATargetJustBelowASegmentStart() {
        let starts: [Double] = [0, 10, 20, 30, 40]
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 29.5, starts: starts), 2)
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 28.9, starts: starts), 1)
        // Short segments cap the tolerance at half a segment, so it cannot skip one.
        let short: [Double] = [0, 0.4, 0.8, 1.2]
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 0.79, starts: short), 1)
    }

    func testRestartSegmentIndexClampsAtBothEnds() {
        let starts: [Double] = [0, 6, 12]
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 0, starts: starts), 0)
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: -5, starts: starts), 0)
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 9_999, starts: starts), 1)
        XCTAssertEqual(HLSVODIngestReader.restartSegmentIndex(forElapsed: 3, starts: []), 0)
    }

    /// The reader's axis is elapsed media time, so a seek must resume with the bytes of the segment it
    /// named, not the ones the previous producer had queued. Each segment carries its index as a marker
    /// byte, which makes the first post-seek read the assertion.
    func testSeekResumesWithThePrecedingSegmentsBytes() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/multi.m3u8"))
        let names = (0..<5).map { "seg\($0).ts" }
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist(names)
        for (index, name) in names.enumerated() {
            Issue268URLProtocol.bodyByURL["https://vod.test/\(name)"] =
                transportStream(streamType: 0x24, marker: UInt8(index))
        }

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        XCTAssertEqual(reader.mediaDuration, 30, accuracy: 0.001)
        XCTAssertTrue(reader.seek(to: 20))
        var bytes = [UInt8](repeating: 0, count: 188)
        let count = bytes.withUnsafeMutableBufferPointer {
            reader.read($0.baseAddress, size: Int32($0.count))
        }
        XCTAssertEqual(count, 188)
        XCTAssertEqual(bytes[0], 0x47)
        XCTAssertEqual(bytes[Self.markerOffset], 2, "20s sits in segment 3, so the ingest restarts at 2")
    }

    /// The reader publishes the playlist's own boundaries so the segment plan can be built on them
    /// instead of a synthetic grid that lands between the source's IRAPs (AE#268).
    func testReaderPublishesItsSegmentStarts() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/starts.m3u8"))
        let names = (0..<5).map { "starts\($0).ts" }
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist(names)
        for (index, name) in names.enumerated() {
            Issue268URLProtocol.bodyByURL["https://vod.test/\(name)"] =
                transportStream(streamType: 0x24, marker: UInt8(index))
        }

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        XCTAssertEqual(reader.segmentStartTimesSeconds, [0, 6, 12, 18, 24])
    }

    /// Byte seeks stay refused: the concatenated segment stream has no address space, and answering a
    /// rewind that never happened would let libavformat binary-search over HTTP.
    func testByteSeekOnlyAcceptsANoOpReposition() async throws {
        let root = try XCTUnwrap(URL(string: "https://vod.test/byteseek.m3u8"))
        let segment = try XCTUnwrap(URL(string: "https://vod.test/byteseek.ts"))
        Issue268URLProtocol.bodyByURL[root.absoluteString] = mediaPlaylist("byteseek.ts")
        Issue268URLProtocol.bodyByURL[segment.absoluteString] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: root,
            httpHeaders: [:],
            session: session
        )
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_SET), 0, "capability handshake at position 0")
        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_CUR), 0)
        XCTAssertEqual(reader.seek(offset: 4096, whence: SEEK_SET), -1)
        XCTAssertEqual(reader.seek(offset: 0, whence: 65536), -1, "AVSEEK_SIZE: no byte length exists")

        var bytes = [UInt8](repeating: 0, count: 188)
        _ = bytes.withUnsafeMutableBufferPointer {
            reader.read($0.baseAddress, size: Int32($0.count))
        }
        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_SET), -1, "a real rewind is not available")
    }

    // MARK: - Prefetch bound

    /// The window is bounded by bytes, not by segment count: four 4K VOD segments in flight would peak
    /// near 100 MB on a device that also holds decode buffers (AE#255).
    func testPrefetchWindowNarrowsWithSegmentSize() {
        XCTAssertEqual(HLSVODIngestReader.prefetchWindow(forSegmentBytes: 2 * 1024 * 1024), 4)
        XCTAssertEqual(HLSVODIngestReader.prefetchWindow(forSegmentBytes: 8 * 1024 * 1024), 3)
        XCTAssertEqual(HLSVODIngestReader.prefetchWindow(forSegmentBytes: 25 * 1024 * 1024), 1)
        XCTAssertEqual(HLSVODIngestReader.prefetchWindow(forSegmentBytes: 0), 4)
    }

    // MARK: - Carriage probe

    func testCarriageProbeReadsTheVerdictFromThePMT() {
        XCTAssertEqual(
            MPEGTransportStreamCodecProbe.classify(transportStream(streamType: 0x24)),
            .hevcInMPEGTS
        )
        XCTAssertEqual(
            MPEGTransportStreamCodecProbe.classify(transportStream(streamType: 0x1B)),
            .otherCarriage,
            "H.264 in MPEG-TS is carriage AVPlayer builds itself"
        )
    }

    func testCarriageProbeWithoutEvidenceStaysInconclusive() {
        XCTAssertEqual(MPEGTransportStreamCodecProbe.classify(Data()), .inconclusive)
        XCTAssertEqual(
            MPEGTransportStreamCodecProbe.classify(Data([0x47, 0x40, 0x00])),
            .inconclusive,
            "TS sync but not a full packet yet"
        )
        var withoutPMT = transportStream(streamType: 0x24)
        withoutPMT[5] = 0x00 // table_id PAT: no program map in this packet
        XCTAssertEqual(MPEGTransportStreamCodecProbe.classify(withoutPMT), .inconclusive)
    }

    func testCarriageProbeRejectsNonTransportStreamCarriage() {
        let fragmentedMP4 = Data([0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70])
        XCTAssertEqual(MPEGTransportStreamCodecProbe.classify(fragmentedMP4), .otherCarriage)
    }

    private static let markerOffset = 30

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue268URLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func mediaPlaylist(_ segment: String) -> Data {
        mediaPlaylist([segment])
    }

    private func mediaPlaylist(_ segments: [String]) -> Data {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n"
        for segment in segments {
            text += "#EXTINF:6,\n\(segment)\n"
        }
        return Data((text + "#EXT-X-ENDLIST").utf8)
    }

    /// Marker byte sits past the PMT section and inside the first packet's filler, so it never
    /// disturbs the parse it is shipped with.
    private func transportStream(streamType: UInt8, marker: UInt8) -> Data {
        var bytes = transportStream(streamType: streamType)
        bytes[Self.markerOffset] = marker
        return bytes
    }

    private func transportStream(streamType: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * 3)
        for packet in 0..<3 {
            bytes[packet * 188] = 0x47
            bytes[packet * 188 + 3] = 0x10
        }
        bytes[1] = 0x40
        bytes[2] = 0x64
        bytes[4] = 0
        bytes[5] = 0x02
        bytes[6] = 0xB0
        bytes[7] = 18
        bytes[8] = 0
        bytes[9] = 1
        bytes[10] = 0xC1
        bytes[11] = 0
        bytes[12] = 0
        bytes[13] = 0xE1
        bytes[14] = 0
        bytes[15] = 0xF0
        bytes[16] = 0
        bytes[17] = streamType
        bytes[18] = 0xE1
        bytes[19] = 1
        bytes[20] = 0xF0
        bytes[21] = 0
        return Data(bytes)
    }
}

final class Issue268URLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodyByURL: [String: Data] = [:]
    nonisolated(unsafe) static var headersByURL: [String: [String: String]] = [:]

    static func reset() {
        bodyByURL = [:]
        headersByURL = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.headersByURL[url.absoluteString] = request.allHTTPHeaderFields ?? [:]
        guard let data = Self.bodyByURL[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: request.value(forHTTPHeaderField: "Range") == nil ? 200 : 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
