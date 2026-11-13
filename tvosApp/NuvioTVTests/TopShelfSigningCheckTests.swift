import XCTest
@testable import NuvioTV

final class TopShelfSigningCheckTests: XCTestCase {
    private let group = "group.com.example.nuvio"

    func testSigningWithTheGroupInAppAndExtensionHasNoProblem() {
        XCTAssertNil(diagnose(appOpensGroup: true, appProfile: [group], extensionProfile: [group]))
    }

    func testBuildWithoutProfilesHasNoProblemWhenTheAppOpensTheGroup() {
        // App Store and TestFlight builds carry no embedded profile.
        XCTAssertNil(diagnose(appOpensGroup: true, appProfile: nil, extensionProfile: nil))
    }

    func testMissingExtensionComesFirst() {
        XCTAssertEqual(
            diagnose(appOpensGroup: false, appProfile: [], hasExtension: false, extensionProfile: nil),
            .extensionMissing
        )
    }

    func testAppProfileWithoutGroup() {
        XCTAssertEqual(
            diagnose(appOpensGroup: false, appProfile: [], extensionProfile: []),
            .appWithoutGroup(profileGroups: [])
        )
    }

    func testAppProfileAllowsAGroupTheSignatureLeftOut() {
        XCTAssertEqual(
            diagnose(appOpensGroup: false, appProfile: ["group.other"], extensionProfile: ["group.other"]),
            .appWithoutGroup(profileGroups: ["group.other"])
        )
    }

    func testAppWithoutProfileThatCannotOpenTheGroup() {
        XCTAssertEqual(
            diagnose(appOpensGroup: false, appProfile: nil, extensionProfile: nil),
            .appWithoutGroup(profileGroups: nil)
        )
    }

    func testExtensionProfileWithoutTheAppsGroup() {
        XCTAssertEqual(
            diagnose(appOpensGroup: true, appProfile: [group], extensionProfile: []),
            .extensionWithoutGroup
        )
        XCTAssertEqual(
            diagnose(appOpensGroup: true, appProfile: [group], extensionProfile: ["group.other"]),
            .extensionWithoutGroup
        )
    }

    private func diagnose(
        appOpensGroup: Bool,
        appProfile: [String]?,
        hasExtension: Bool = true,
        extensionProfile: [String]?
    ) -> TopShelfSigningCheck.Problem? {
        TopShelfSigningCheck.diagnose(
            groupID: group,
            appOpensGroup: appOpensGroup,
            appProfileGroups: appProfile,
            hasExtension: hasExtension,
            extensionProfileGroups: extensionProfile
        )
    }
}
