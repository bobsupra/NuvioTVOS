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

    func testFrenchTranslations() {
        L10n.reload(languageTag: "fr")
        XCTAssertEqual(L10n.string("nav_calendar", fallback: "Calendar"), "Calendrier")
        XCTAssertEqual(L10n.string("calendar_home_today_row", fallback: "Today"), "Aujourd'hui")
        XCTAssertEqual(L10n.string("calendar_today", fallback: "Today"), "Aujourd'hui")
        XCTAssertEqual(L10n.string("calendar_home_today_badge", fallback: "AIRING TODAY"), "Diffusion Aujourd'hui")
        XCTAssertEqual(
            L10n.string("profile_background_title", fallback: "Profile Background"),
            "Fond d'écran d'arrière plan de l'écran de sélection de profil"
        )
        XCTAssertEqual(
            L10n.string("profile_background_subtitle", fallback: ""),
            "Personnalisez le fond d'écran qui apparaît a l'arrière du sélecteur de profil avec l'un des arrières plan préconfigurés ou via un URL personnalisé"
        )
        XCTAssertEqual(L10n.string("settings_sidebar_tabs", fallback: "Sidebar"), "Sidebar")
        XCTAssertEqual(
            L10n.string("settings_sidebar_tabs_subtitle", fallback: ""),
            "Choisissez les sections disponibles dans la sidebar"
        )
        XCTAssertEqual(
            L10n.string("settings_show_calendar_tab_subtitle", fallback: ""),
            "Épisodes à venir et sorties de votre catalogue"
        )
        XCTAssertEqual(L10n.string("nav_watch_party", fallback: "Watch Party"), "Watch Party")
        XCTAssertEqual(
            L10n.string("settings_show_watch_party_tab_subtitle", fallback: ""),
            "Afficher Watch Party dans la sidebar"
        )

        // Reset to system
        L10n.reload(languageTag: nil)
    }

    func testAndroidImportedTranslations() {
        L10n.reload(languageTag: "fr")
        XCTAssertEqual(L10n.string("parental_violence", fallback: "Violence"), "Violence")
        XCTAssertEqual(L10n.string("skip_intro", fallback: "Skip Intro"), "Passer l’intro")
        XCTAssertEqual(L10n.string("player_chapters", fallback: "Chapters"), "Chapitres")
        XCTAssertEqual(L10n.string("calendar_tomorrow", fallback: "Tomorrow"), "Demain")

        L10n.reload(languageTag: "es")
        XCTAssertEqual(L10n.string("parental_violence", fallback: "Violence"), "Violencia")
        XCTAssertEqual(L10n.string("skip_intro", fallback: "Skip Intro"), "Saltar introducción")
        XCTAssertEqual(L10n.string("player_chapters", fallback: "Chapters"), "Capítulos")
        XCTAssertEqual(L10n.string("calendar_tomorrow", fallback: "Tomorrow"), "Mañana")

        L10n.reload(languageTag: "ja")
        XCTAssertEqual(L10n.string("parental_violence", fallback: "Violence"), "暴力")
        XCTAssertEqual(L10n.string("skip_intro", fallback: "Skip Intro"), "イントロをスキップ")
        XCTAssertEqual(L10n.string("player_chapters", fallback: "Chapters"), "チャプター")
        XCTAssertEqual(L10n.string("calendar_tomorrow", fallback: "Tomorrow"), "明日")

        // Reset to system
        L10n.reload(languageTag: nil)
    }

    func testSettingsOptionTranslations() {
        L10n.reload(languageTag: "no")
        XCTAssertEqual(L10n.optionLabel("Always"), "Alltid")
        XCTAssertEqual(L10n.optionLabel("Focused Only"), "Kun ved fokus")
        XCTAssertEqual(L10n.optionLabel("Hidden"), "Skjult")
        XCTAssertEqual(L10n.optionLabel("Sharp (0pt)"), "Skarp (0 pt)")
        XCTAssertEqual(L10n.optionLabel("Subtle (8pt)"), "Subtil (8 pt)")
        XCTAssertEqual(L10n.optionLabel("Classic (16pt)"), "Klassisk (16 pt)")
        XCTAssertEqual(L10n.optionLabel("Grid View"), "Rutenettvisning")
        XCTAssertEqual(L10n.optionLabel("Top"), "Topp")
        XCTAssertEqual(L10n.optionLabel("Bottom"), "Bunn")
        XCTAssertEqual(L10n.optionLabel("Featured Card & Posters"), "Utvalgt kort og plakater")
        XCTAssertEqual(L10n.optionLabel("Small"), "Liten")
        XCTAssertEqual(L10n.optionLabel("Wide"), "Bred")

        L10n.reload(languageTag: "en")
        XCTAssertEqual(L10n.optionLabel("Always"), "Always")
        XCTAssertEqual(L10n.optionLabel("Focused Only"), "Focused Only")
        XCTAssertEqual(L10n.optionLabel("Hidden"), "Hidden")
        XCTAssertEqual(L10n.optionLabel("Sharp (0pt)"), "Sharp (0pt)")
        XCTAssertEqual(L10n.optionLabel("Grid View"), "Grid View")
        XCTAssertEqual(L10n.optionLabel("Featured Card & Posters"), "Featured Card & Posters")

        // Reset to system
        L10n.reload(languageTag: nil)
    }

    func testWatchPartyTranslations() {
        L10n.reload(languageTag: "no")
        XCTAssertEqual(L10n.string("party_join_room_title", fallback: "Join a room"), "Bli med i et rom")
        XCTAssertEqual(L10n.string("party_leave_room_title", fallback: "Leave room"), "Forlat rom")
        XCTAssertEqual(L10n.string("party_badge_host", fallback: "Host"), "Vert")
        XCTAssertEqual(L10n.string("party_badge_you", fallback: "You"), "Deg")
        XCTAssertEqual(L10n.string("party_the_host", fallback: "The host"), "Verten")
        XCTAssertEqual(L10n.string("party_conn_connected", fallback: "Connected"), "Tilkoblet")
        XCTAssertEqual(L10n.format("party_members_count", fallback: "%d of %d members", 2, 8), "2 av 8 medlemmer")

        L10n.reload(languageTag: "fr")
        XCTAssertEqual(L10n.string("party_join_room_title", fallback: "Join a room"), "Rejoindre un salon")
        XCTAssertEqual(L10n.string("party_leave_room_title", fallback: "Leave room"), "Quitter le salon")
        XCTAssertEqual(L10n.string("party_badge_host", fallback: "Host"), "Hôte")
        XCTAssertEqual(L10n.string("party_badge_you", fallback: "You"), "Vous")
        XCTAssertEqual(L10n.string("party_the_host", fallback: "The host"), "L'hôte")
        XCTAssertEqual(L10n.string("party_conn_connected", fallback: "Connected"), "Connecté")
        XCTAssertEqual(L10n.format("party_members_count", fallback: "%d of %d members", 2, 8), "2 sur 8 membres")

        // Reset to system
        L10n.reload(languageTag: nil)
    }
}
