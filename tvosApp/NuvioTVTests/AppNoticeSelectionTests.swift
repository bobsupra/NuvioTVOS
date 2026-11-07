import Foundation
import XCTest
@testable import NuvioTV

final class AppNoticeSelectionTests: XCTestCase {
    func testReleaseHasPriorityAndNoticeIDsAreNamespaced() throws {
        let tag = "tvos-beta-3.4.7"
        let release = try XCTUnwrap(ReleaseUpdateMetadata(
            tagName: tag,
            releaseURLString: "https://github.com/\(AppRepository.slug)/releases/tag/\(tag)"
        ))
        let announcement = makeAnnouncement(id: tag)

        let selected = AppNotice.select(
            release: release,
            releaseIsAvailable: true,
            announcementsEnabled: true,
            activeAnnouncements: [announcement],
            skippedAnnouncementIDs: [],
            dismissedAnnouncementIDs: []
        )

        XCTAssertEqual(selected, .release(release))
        XCTAssertEqual(AppNotice.release(release).id, "release:\(tag)")
        XCTAssertEqual(AppNotice.announcement(announcement).id, "announcement:\(tag)")
        XCTAssertNotEqual(AppNotice.release(release).id, AppNotice.announcement(announcement).id)
    }

    func testSelectionReturnsFirstEligibleAnnouncementWithoutStacking() {
        let first = makeAnnouncement(id: "first-note")
        let second = makeAnnouncement(id: "second-note")
        let messages = [first, second]

        let afterFirstIsSkipped = AppNotice.select(
            release: nil,
            releaseIsAvailable: false,
            announcementsEnabled: true,
            activeAnnouncements: messages,
            skippedAnnouncementIDs: [first.id],
            dismissedAnnouncementIDs: []
        )
        XCTAssertEqual(afterFirstIsSkipped, .announcement(second))

        let afterFirstIsDismissed = AppNotice.select(
            release: nil,
            releaseIsAvailable: false,
            announcementsEnabled: true,
            activeAnnouncements: messages,
            skippedAnnouncementIDs: [],
            dismissedAnnouncementIDs: [first.id]
        )
        XCTAssertEqual(afterFirstIsDismissed, .announcement(second))
    }

    func testDisabledAnnouncementsAndIneligibleMessagesProduceNoNotice() {
        let announcement = makeAnnouncement(id: "notice")
        XCTAssertNil(AppNotice.select(
            release: nil,
            releaseIsAvailable: false,
            announcementsEnabled: false,
            activeAnnouncements: [announcement],
            skippedAnnouncementIDs: [],
            dismissedAnnouncementIDs: []
        ))
        XCTAssertNil(AppNotice.select(
            release: nil,
            releaseIsAvailable: false,
            announcementsEnabled: true,
            activeAnnouncements: [announcement],
            skippedAnnouncementIDs: [announcement.id],
            dismissedAnnouncementIDs: []
        ))
    }

    private func makeAnnouncement(id: String) -> Announcement {
        Announcement(
            id: id,
            title: "Maintenance notice",
            message: "Read the latest update.",
            linkURL: nil,
            startsAt: nil,
            endsAt: nil
        )
    }
}
