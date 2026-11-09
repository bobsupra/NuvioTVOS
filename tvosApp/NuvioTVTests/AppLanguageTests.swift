//
//  AppLanguageTests.swift
//  NuvioTVTests
//

import XCTest
@testable import NuvioTV

final class AppLanguageTests: XCTestCase {
    func testAllLanguagesCount() {
        // System + 38 localized languages = 39 cases
        XCTAssertEqual(AppLanguage.allCases.count, 39)
    }

    func testNewAndroidLanguagesExist() {
        let cases = Set(AppLanguage.allCases)
        XCTAssertTrue(cases.contains(.bengali))
        XCTAssertTrue(cases.contains(.croatian))
        XCTAssertTrue(cases.contains(.albanian))
        XCTAssertTrue(cases.contains(.serbianLatin))
    }

    func testTags() {
        XCTAssertEqual(AppLanguage.bengali.tag, "bn")
        XCTAssertEqual(AppLanguage.croatian.tag, "hr")
        XCTAssertEqual(AppLanguage.albanian.tag, "sq")
        XCTAssertEqual(AppLanguage.serbianLatin.tag, "sr-Latn")
    }

    func testFromStored() {
        XCTAssertEqual(AppLanguage.fromStored("bn"), .bengali)
        XCTAssertEqual(AppLanguage.fromStored("hr"), .croatian)
        XCTAssertEqual(AppLanguage.fromStored("sq"), .albanian)
        XCTAssertEqual(AppLanguage.fromStored("sr-Latn"), .serbianLatin)
        XCTAssertEqual(AppLanguage.fromStored("sr-latn"), .serbianLatin)
        XCTAssertEqual(AppLanguage.fromStored("sr"), .serbianLatin)

        // Legacy name mapping
        XCTAssertEqual(AppLanguage.fromStored("Croatian"), .croatian)
        XCTAssertEqual(AppLanguage.fromStored("Bengali"), .bengali)
        XCTAssertEqual(AppLanguage.fromStored("Albanian"), .albanian)
        XCTAssertEqual(AppLanguage.fromStored("Serbian"), .serbianLatin)
    }

    func testAudioLanguageNames() {
        XCTAssertEqual(AppLanguage.bengali.audioLanguageName, "Bengali")
        XCTAssertEqual(AppLanguage.croatian.audioLanguageName, "Croatian")
        XCTAssertEqual(AppLanguage.albanian.audioLanguageName, "Albanian")
        XCTAssertEqual(AppLanguage.serbianLatin.audioLanguageName, "Serbian")
    }

    func testPickerLanguagesIncludesAll() {
        let picker = AppLanguage.pickerLanguages
        XCTAssertEqual(picker.count, 39)
        XCTAssertEqual(picker.first, .system)

        let pickerSet = Set(picker)
        XCTAssertTrue(pickerSet.contains(.bengali))
        XCTAssertTrue(pickerSet.contains(.croatian))
        XCTAssertTrue(pickerSet.contains(.albanian))
        XCTAssertTrue(pickerSet.contains(.serbianLatin))
    }

    func testNativeDisplayNamesNonEmpty() {
        for lang in AppLanguage.allCases {
            XCTAssertFalse(lang.nativeDisplayName.isEmpty, "Native display name should not be empty for \(lang)")
        }
    }

    func testL10nReloadWithNewLanguages() {
        L10n.reload(languageTag: "bn")
        XCTAssertEqual(L10n.string("nav_home", fallback: "Home"), "হোম")

        L10n.reload(languageTag: "hr")
        XCTAssertEqual(L10n.string("nav_home", fallback: "Home"), "Početna")

        L10n.reload(languageTag: "sq")
        XCTAssertEqual(L10n.string("nav_home", fallback: "Home"), "Faqja kryesore")

        L10n.reload(languageTag: "sr-Latn")
        XCTAssertEqual(L10n.string("nav_home", fallback: "Home"), "Početna")

        // Reset to system
        L10n.reload(languageTag: nil)
    }
}
