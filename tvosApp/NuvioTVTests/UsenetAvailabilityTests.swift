import Foundation
import XCTest
@testable import NuvioTV

final class UsenetAvailabilityTests: XCTestCase {
    private func file(_ name: String, segments: Int, declared: Int? = nil, numbers: [Int]? = nil) -> UsenetFile {
        let total = declared ?? segments
        let subject = "[01/09] - \"\(name)\" yEnc (1/\(total))"
        let list = (numbers ?? Array(1...segments)).map {
            UsenetSegment(messageID: "\(name)-\($0)@test", bytes: 700_000, number: $0)
        }
        return UsenetFile(subject: subject, name: name, segments: list)
    }

    private func nzb(_ files: [UsenetFile]) -> UsenetNZB {
        UsenetNZB(title: nil, password: nil, files: files)
    }

    // MARK: Reading the NZB

    func testDeclaredSegmentsComeFromTheLastCountInTheSubject() {
        XCTAssertEqual(UsenetAvailability.declaredSegments(inSubject: "[01/15] - \"x.part01.rar\" yEnc (1/52)"), 52)
        XCTAssertEqual(UsenetAvailability.declaredSegments(inSubject: "x.mkv (3/7) yEnc (1/120)"), 120)
        XCTAssertNil(UsenetAvailability.declaredSegments(inSubject: "\"x.mkv\" yEnc"))
    }

    func testGapsAreTheArticlesTheNZBDoesNotList() {
        XCTAssertEqual(UsenetAvailability.gaps(in: file("a.mkv", segments: 3, declared: 5, numbers: [1, 2, 4])), 2)
        XCTAssertEqual(UsenetAvailability.gaps(in: file("a.mkv", segments: 5)), 0)
        let unannounced = UsenetFile(subject: "a.mkv", name: "a.mkv", segments: [UsenetSegment(messageID: "x", bytes: 1, number: 1)])
        XCTAssertEqual(UsenetAvailability.gaps(in: unannounced), 0)
    }

    func testMissingVolumesOfNumberedSets() {
        XCTAssertEqual(UsenetAvailability.missingVolumes(in: ["x.part01.rar", "x.part02.rar", "x.part04.rar"]), 1)
        XCTAssertEqual(UsenetAvailability.missingVolumes(in: ["x.rar", "x.r00", "x.r02"]), 1)
        // The old naming starts with .rar.
        XCTAssertEqual(UsenetAvailability.missingVolumes(in: ["x.r00", "x.r01"]), 1)
        XCTAssertEqual(UsenetAvailability.missingVolumes(in: ["x.rar"]), 0)
        XCTAssertEqual(UsenetAvailability.missingVolumes(in: ["x.part001.rar", "x.part002.rar"]), 0)
        // Each set on its own (a season of RAR sets).
        XCTAssertEqual(UsenetAvailability.missingVolumes(in: ["e01.part1.rar", "e01.part3.rar", "e02.part1.rar", "e02.part2.rar"]), 1)
        XCTAssertEqual(UsenetAvailability.missingVolumes(in: ["movie.mkv", "abcdef0123"]), 0)
    }

    func testContentFilesLeaveOutSidecarsAndGoInVolumeOrder() {
        let files = UsenetAvailability.contentFiles(of: nzb([
            file("x.r01", segments: 2), file("x.nfo", segments: 1), file("x.rar", segments: 2),
            file("x.r00", segments: 2), file("x.vol00+01.par2", segments: 2),
        ]), mustInclude: nil)
        XCTAssertEqual(files.map(\.name), ["x.rar", "x.r00", "x.r01"])
    }

    func testAnObfuscatedReleaseKeepsEverythingButSidecarsInNZBOrder() {
        let files = UsenetAvailability.contentFiles(of: nzb([
            file("9f2c1e", segments: 2), file("x.par2", segments: 1), file("41ab07", segments: 2),
        ]), mustInclude: nil)
        XCTAssertEqual(files.map(\.name), ["9f2c1e", "41ab07"])
    }

    func testAnEpisodeOfAPackIsCheckedAlone() {
        let files = UsenetAvailability.contentFiles(of: nzb([
            file("Show.S01E01.mkv", segments: 2), file("Show.S01E02.mkv", segments: 2),
        ]), mustInclude: "S01E02")
        XCTAssertEqual(files.map(\.name), ["Show.S01E02.mkv"])
    }

    func testVolumesWithFewerArticlesThanTheirSetAreShort() {
        // Five volumes of 50 articles and a smaller last one: the last is left out.
        var files = (1...6).map { file("x.part0\($0).rar", segments: $0 == 6 ? 12 : 50) }
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: files).short, 0)
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: files).judged, 5)
        files[2] = file("x.part03.rar", segments: 46)
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: files).short, 1)
        // A longer volume is no hole.
        files[3] = file("x.part04.rar", segments: 53)
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: files).short, 1)
        // The old naming, and each set on its own.
        let old = ["x.rar", "x.r00", "x.r01", "x.r02"].map { file($0, segments: $0 == "x.r01" ? 40 : 50) }
        let other = (1...3).map { file("y.part\($0).rar", segments: 30) }
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: old + other).short, 1)
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: old + other).judged, 5)
    }

    func testSmallSetsAndObfuscatedFilesAreNotJudged() {
        let pair = [file("x.part1.rar", segments: 50), file("x.part2.rar", segments: 20)]
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: pair).judged, 0)
        let obfuscated = [file("9f2c1e", segments: 50), file("41ab07", segments: 20), file("77de10", segments: 50)]
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: obfuscated).judged, 0)
        let plain = [file("movie.mkv", segments: 900)]
        XCTAssertEqual(UsenetAvailability.shortVolumes(in: plain).judged, 0)
    }

    // MARK: The plan

    func testThePlanSpreadsTheSamplesAndEndsOnTheLastArticle() {
        let plan = UsenetAvailability.plan(for: nzb([
            file("x.part01.rar", segments: 40), file("x.part02.rar", segments: 40), file("x.nfo", segments: 1),
        ]))
        XCTAssertEqual(plan.samples.count, UsenetHealthCheck.sampleCount)
        XCTAssertEqual(Set(plan.samples).count, plan.samples.count)
        XCTAssertEqual(plan.samples.first, "x.part01.rar-1@test")
        XCTAssertEqual(plan.samples.last, "x.part02.rar-40@test")
        XCTAssertFalse(plan.tailMissingInNZB)
        XCTAssertEqual(plan.nzbGaps, 0)
        XCTAssertEqual(plan.missingVolumes, 0)
        XCTAssertEqual(plan.judgedVolumes, 0, "two volumes are too few to compare")
    }

    func testThePlanCountsShortVolumes() {
        let plan = UsenetAvailability.plan(for: nzb([
            file("x.part1.rar", segments: 40), file("x.part2.rar", segments: 31),
            file("x.part3.rar", segments: 40), file("x.part4.rar", segments: 40), file("x.part5.rar", segments: 9),
        ]))
        XCTAssertEqual(plan.shortVolumes, 1)
        XCTAssertEqual(plan.judgedVolumes, 4)
    }

    func testAShortReleaseIsAskedAboutWhole() {
        let plan = UsenetAvailability.plan(for: nzb([file("a.mkv", segments: 3)]))
        XCTAssertEqual(plan.samples, ["a.mkv-1@test", "a.mkv-2@test", "a.mkv-3@test"])
    }

    func testAnNZBWithoutTheLastArticleHasItsEndMissing() {
        let plan = UsenetAvailability.plan(for: nzb([file("a.mkv", segments: 9, declared: 10)]))
        XCTAssertTrue(plan.tailMissingInNZB)
        XCTAssertEqual(plan.nzbGaps, 1)
    }

    func testTwoArticlesFromInsideTheReleaseAreDownloaded() {
        let plan = UsenetAvailability.plan(for: nzb([
            file("x.part01.rar", segments: 40), file("x.part02.rar", segments: 40),
        ]))
        XCTAssertEqual(plan.downloads.count, UsenetAvailability.bodyProbes)
        XCTAssertEqual(plan.downloads, [plan.samples[3], plan.samples[7]])
        XCTAssertFalse(plan.downloads.contains(plan.samples.first!))
        XCTAssertFalse(plan.downloads.contains(plan.samples.last!))
    }

    func testAReleaseOfTwoArticlesIsOnlyAskedAbout() {
        let plan = UsenetAvailability.plan(for: nzb([file("a.mkv", segments: 2)]))
        XCTAssertEqual(plan.samples.count, 2)
        XCTAssertTrue(plan.downloads.isEmpty)
    }

    // MARK: The verdict

    private func report(missing: Int = 0, tail: Bool = false, gaps: Int = 0, volumes: Int = 0) -> UsenetAvailabilityReport {
        UsenetAvailabilityReport(checked: 12, missing: missing, tailMissing: tail, nzbGaps: gaps, missingVolumes: volumes)
    }

    func testTheVerdictMatchesWhatPlaybackStarts() {
        XCTAssertEqual(report().verdict, .available)
        XCTAssertEqual(report(missing: 1).verdict, .partial)
        XCTAssertEqual(report(gaps: 2).verdict, .partial)
        // What playback wouldn't start (UsenetHealthCheck.isPlayable).
        XCTAssertEqual(report(missing: 2).verdict, .incomplete)
        XCTAssertEqual(report(tail: true).verdict, .incomplete)
        // Whole parts missing.
        XCTAssertEqual(report(volumes: 1).verdict, .incomplete)
        XCTAssertEqual(report(gaps: UsenetAvailabilityReport.nzbGapsLimit).verdict, .incomplete)
    }

    func testShortVolumesMakeItPartialAndManyIncomplete() {
        var checked = report()
        checked.shortVolumes = 1
        checked.judgedVolumes = 10
        XCTAssertEqual(checked.verdict, .partial)
        checked.shortVolumes = 2
        XCTAssertEqual(checked.verdict, .partial, "a fifth is still partial")
        checked.shortVolumes = 3
        XCTAssertTrue(checked.volumesLookIncomplete)
        XCTAssertEqual(checked.verdict, .incomplete)
        checked.shortVolumes = 0
        XCTAssertEqual(checked.verdict, .available)
    }

    func testAReportSavedBeforeShortVolumesStillLoads() throws {
        let saved = Data(#"{"checked":12,"missing":0,"tailMissing":false,"nzbGaps":0,"missingVolumes":0,"downloaded":2,"played":false}"#.utf8)
        let report = try JSONDecoder().decode(UsenetAvailabilityReport.self, from: saved)
        XCTAssertNil(report.shortVolumes)
        XCTAssertNil(report.judgedVolumes)
        XCTAssertEqual(report.verdict, .available)
    }

    func testWhatPlaybackShowedMakesItIncomplete() {
        var played = report()
        played.playbackProblem = .damaged
        XCTAssertEqual(played.verdict, .incomplete)
        played.playbackProblem = .wouldNotStart
        XCTAssertEqual(played.verdict, .incomplete)
    }

    func testAReportSurvivesBeingSaved() throws {
        var saved = report(missing: 3, tail: true, gaps: 1, volumes: 2)
        saved.downloaded = 2
        saved.shortVolumes = 1
        saved.judgedVolumes = 8
        saved.playbackProblem = .damaged
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(UsenetAvailabilityReport.self, from: data), saved)
    }

    // MARK: Failed starts

    func testAFailedReleaseCheckKeepsItsNumbers() {
        let health = UsenetHealthCheck.Result(checked: 12, missing: 4, tailMissing: false)
        let failed = UsenetEngineManager.startFailureReport(UsenetError.releaseIncomplete, health: health)
        XCTAssertEqual(failed?.missing, 4)
        XCTAssertEqual(failed?.checked, 12)
        XCTAssertNil(failed?.playbackProblem)
        XCTAssertEqual(failed?.verdict, .incomplete)
    }

    func testAStartWithoutItsFirstArticleWouldNotStart() {
        let failed = UsenetEngineManager.startFailureReport(UsenetError.firstSegmentUnavailable, health: nil)
        XCTAssertEqual(failed?.playbackProblem, .wouldNotStart)
        // Its first articles gone after a release check that passed.
        let passed = UsenetHealthCheck.Result(checked: 12, missing: 0, tailMissing: false)
        XCTAssertEqual(UsenetEngineManager.startFailureReport(UsenetError.releaseIncomplete, health: passed)?.playbackProblem, .wouldNotStart)
    }

    func testOtherFailedStartsAreNotHeldAgainstTheRelease() {
        XCTAssertNil(UsenetEngineManager.startFailureReport(UsenetError.noServers, health: nil))
        XCTAssertNil(UsenetEngineManager.startFailureReport(UsenetError.nzbDownloadFailed(503), health: nil))
        XCTAssertNil(UsenetEngineManager.startFailureReport(URLError(.timedOut), health: nil))
    }

    // MARK: Remembered

    private func defaults() -> (UserDefaults, String) {
        let suite = "usenet-remembered-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private let spec = UsenetStreamSpec(nzbURL: URL(string: "https://indexer.example/api?t=get&id=42&apikey=SECRETKEY")!)

    @MainActor
    func testAStreamThatPlayedDamagedIsRememberedOnThisDevice() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        var damaged = report()
        damaged.playbackProblem = .damaged
        UsenetAvailabilityChecker(defaults: store).recordPlayback(spec, report: damaged)

        let later = UsenetAvailabilityChecker(defaults: store)
        XCTAssertEqual(later.state(for: spec), .checked(damaged))
        // Another episode of the same pack is its own.
        var episode = spec
        episode.fileMustInclude = "S01E02"
        XCTAssertNil(later.state(for: episode))
    }

    @MainActor
    func testTheNZBURLIsNotSaved() throws {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        UsenetAvailabilityChecker(defaults: store).recordPlayback(spec, report: report(missing: 5))
        let data = try XCTUnwrap(store.data(forKey: UsenetAvailabilityChecker.rememberedKey))
        let saved = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(saved.contains("SECRETKEY"))
        XCTAssertFalse(saved.contains("indexer.example"))
    }

    @MainActor
    func testFoundAvailableItIsForgotten() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let checker = UsenetAvailabilityChecker(defaults: store)
        checker.recordPlayback(spec, report: report(missing: 5))
        checker.recordPlayback(spec, report: report())
        XCTAssertNil(UsenetAvailabilityChecker(defaults: store).state(for: spec))
    }

    @MainActor
    func testWhatWasRememberedExpires() throws {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let old = Date().addingTimeInterval(-UsenetAvailabilityChecker.incompleteLifetime - 60)
        let servers = UsenetAvailabilityChecker(defaults: store).serversDigest(spec)
        let saved = [UsenetAvailabilityChecker.memoryKey(spec): UsenetAvailabilityChecker.Remembered(report: report(missing: 5), at: old, servers: servers)]
        store.set(try JSONEncoder().encode(saved), forKey: UsenetAvailabilityChecker.rememberedKey)
        XCTAssertNil(UsenetAvailabilityChecker(defaults: store).state(for: spec))
    }

    // MARK: Settings

    func testAutomaticChecksAreOffUntilChosen() {
        let suite = "usenet-availability-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), 0)
        UsenetSettings.setAutoCheckCount(5, store: store)
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), 5)
        UsenetSettings.setAutoCheckCount(10, store: store)
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), 10)
        UsenetSettings.setAutoCheckCount(-1, store: store)
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), -1)
        UsenetSettings.setAutoCheckCount(7, store: store)
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), 0)
    }

    // MARK: Remembered like Nuvio on Android TV

    @MainActor
    func testAReleaseThatPlayedIsRememberedAsPlayed() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        UsenetAvailabilityChecker(defaults: store).recordPlayed(spec)
        guard case .checked(let report)? = UsenetAvailabilityChecker(defaults: store).state(for: spec) else {
            return XCTFail("played: remembered")
        }
        XCTAssertTrue(report.played)
        XCTAssertEqual(report.verdict, .available)
    }

    @MainActor
    func testWhatOtherServersShowedDoesNotApply() throws {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let saved = [UsenetAvailabilityChecker.memoryKey(spec): UsenetAvailabilityChecker.Remembered(
            report: report(missing: 5), at: Date(), servers: "another provider"
        )]
        store.set(try JSONEncoder().encode(saved), forKey: UsenetAvailabilityChecker.rememberedKey)
        XCTAssertNil(UsenetAvailabilityChecker(defaults: store).state(for: spec))
    }

    private func usenetStream(_ nzb: String, filename: String?, size: Int64?) -> NuvioStream {
        let url = UsenetStreamSpec(nzbURL: URL(string: nzb)!).url.absoluteString
        return NuvioStream(url: url, name: "Usenet", description: nil, addonName: "U", filename: filename, videoSize: size)
    }

    func testAnotherIndexersCopyHasTheSameNameAndSizeKey() throws {
        let geek = usenetStream("https://geek.example/api?t=get&id=1&apikey=K", filename: "Show.S01E02.1080p.WEB-DL-GRP", size: 1_500_000_000)
        let dog = usenetStream("https://dog.example/getnzb/abc", filename: "Show.S01E02.1080p.WEB-DL-GRP", size: 1_500_200_000)
        let other = usenetStream("https://dog.example/getnzb/def", filename: "Show.S01E02.1080p.WEB-DL-GRP", size: 1_700_000_000)
        func key(_ stream: NuvioStream) -> String? {
            UsenetAvailabilityChecker.titleKey(stream, spec: UsenetAvailabilityChecker.spec(for: stream)!)
        }
        XCTAssertNotNil(key(geek))
        XCTAssertEqual(key(geek), key(dog), "sizes within a MB")
        XCTAssertNotEqual(key(geek), key(other))
        XCTAssertNil(key(usenetStream("https://geek.example/x", filename: nil, size: 1)))
        XCTAssertFalse(try XCTUnwrap(key(geek)).contains("Show"), "only a hash")
    }

    @MainActor
    func testAnIncompleteReleaseIsKnownFromAnotherIndexer() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let geek = usenetStream("https://geek.example/api?t=get&id=1&apikey=K", filename: "Movie.2024.1080p-GRP", size: 9_000_000_000)
        let dog = usenetStream("https://dog.example/getnzb/abc", filename: "Movie.2024.1080p-GRP", size: 9_000_000_000)
        let checker = UsenetAvailabilityChecker(defaults: store)
        _ = checker.state(for: geek)        // the list showed it
        var failed = report()
        failed.playbackProblem = .wouldNotStart
        checker.recordPlayback(UsenetAvailabilityChecker.spec(for: geek)!, report: failed)

        let later = UsenetAvailabilityChecker(defaults: store)
        XCTAssertTrue(later.isIncomplete(dog))
    }
}
