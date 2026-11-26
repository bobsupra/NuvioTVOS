import XCTest
@testable import NuvioTV

final class DetailsFocusedButtonTitleTests: XCTestCase {
    func testSettingSyncsWithTheOtherDetailsPageSettings() {
        XCTAssertEqual(SettingsKey.detailsFocusedButtonTitle, "nuvio.tv.settings.layout.detailsFocusedButtonTitle")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.detailsFocusedButtonTitle))
        XCTAssertFalse(SettingsKey.deviceLocal.contains(SettingsKey.detailsFocusedButtonTitle))
    }

    func testOffPlayAndListButtonsShowTheirTitleAndPlayStaysWhite() {
        for focused in [false, true] {
            XCTAssertTrue(look(isPrimary: true, isFocused: false, rowHasFocus: focused, on: false).title)
            XCTAssertTrue(look(isPrimary: true, isFocused: false, rowHasFocus: focused, on: false).filled)
            XCTAssertTrue(look(isWide: true, isFocused: focused, rowHasFocus: focused, on: false).title)
            XCTAssertFalse(look(isFocused: focused, rowHasFocus: focused, on: false).title)
        }
        XCTAssertTrue(look(isFocused: true, rowHasFocus: true, on: false).filled)
        XCTAssertFalse(look(isFocused: false, rowHasFocus: true, on: false).filled)
    }

    func testOnOnlyTheFocusedButtonShowsItsTitleAndIsWhite() {
        XCTAssertTrue(look(isFocused: true, rowHasFocus: true, on: true).title)
        XCTAssertTrue(look(isFocused: true, rowHasFocus: true, on: true).filled)
        XCTAssertFalse(look(isFocused: false, rowHasFocus: true, on: true).title)
        XCTAssertFalse(look(isFocused: false, rowHasFocus: true, on: true).filled)
        // Play, while another button has focus: icon only, not white.
        XCTAssertFalse(look(isPrimary: true, isFocused: false, rowHasFocus: true, on: true).title)
        XCTAssertFalse(look(isPrimary: true, isFocused: false, rowHasFocus: true, on: true).filled)
    }

    func testOnPlayShowsItsTitleWhileFocusIsElsewhereOnThePage() {
        XCTAssertTrue(look(isPrimary: true, isFocused: false, rowHasFocus: false, on: true).title)
        XCTAssertFalse(look(isPrimary: true, isFocused: false, rowHasFocus: false, on: true).filled)
    }

    func testListStatusAlwaysShowsAndAButtonWithoutTitleNever() {
        XCTAssertTrue(look(isWide: true, isFocused: false, rowHasFocus: true, on: true).title)
        XCTAssertFalse(look(hasTitle: false, isFocused: true, rowHasFocus: true, on: true).title)
        XCTAssertFalse(look(hasTitle: false, isPrimary: true, isFocused: true, rowHasFocus: true, on: false).title)
    }

    private func look(
        hasTitle: Bool = true,
        isPrimary: Bool = false,
        isWide: Bool = false,
        isFocused: Bool,
        rowHasFocus: Bool,
        on: Bool
    ) -> (title: Bool, filled: Bool) {
        (
            DetailsActionButtonLook.showsTitle(
                hasTitle: hasTitle,
                isPrimary: isPrimary,
                isWide: isWide,
                isFocused: isFocused,
                rowHasFocus: rowHasFocus,
                focusedButtonTitle: on
            ),
            DetailsActionButtonLook.isFilled(isPrimary: isPrimary, isFocused: isFocused, focusedButtonTitle: on)
        )
    }
}
