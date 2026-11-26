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

    // MARK: Settings

    func testAutomaticChecksAreOffUntilChosen() {
        let suite = "usenet-availability-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), 0)
        UsenetSettings.setAutoCheckCount(5, store: store)
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), 5)
        UsenetSettings.setAutoCheckCount(-1, store: store)
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), -1)
        UsenetSettings.setAutoCheckCount(7, store: store)
        XCTAssertEqual(UsenetSettings.autoCheckCount(store: store), 0)
    }
}
