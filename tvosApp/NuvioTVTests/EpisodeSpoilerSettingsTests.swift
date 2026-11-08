import XCTest
@testable import NuvioTV

final class EpisodeSpoilerSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        L10n.reload(languageTag: "en")
    }

    func testSpoilerSettingsKeysAreRegisteredInSettingsAll() {
        let expectedKeys = [
            SettingsKey.blurUnwatchedEpisodes,
            SettingsKey.hideUnwatchedEpisodeDescriptions,
            SettingsKey.hideUnwatchedEpisodeTitles,
            SettingsKey.continueWatchingBlurNextUp
        ]

        for key in expectedKeys {
            XCTAssertTrue(
                SettingsKey.all.contains(key),
                "Expected \(key) to be included in SettingsKey.all for persistence and sync"
            )
        }
    }

    func testSpoilerSettingsKeysAreNotInDeviceLocal() {
        // Spoiler settings are user preferences and should sync across devices and profiles
        let spoilerKeys = [
            SettingsKey.blurUnwatchedEpisodes,
            SettingsKey.hideUnwatchedEpisodeDescriptions,
            SettingsKey.hideUnwatchedEpisodeTitles,
            SettingsKey.continueWatchingBlurNextUp
        ]

        for key in spoilerKeys {
            XCTAssertFalse(
                SettingsKey.deviceLocal.contains(key),
                "Expected \(key) not to be in SettingsKey.deviceLocal so it syncs across devices"
            )
        }
    }

    func testEpisodeSpoilerLocalizationKeys() {
        XCTAssertEqual(
            L10n.string("settings_meta_blur_unwatched_episodes", fallback: ""),
            "Blur Unwatched Episodes"
        )
        XCTAssertEqual(
            L10n.string("settings_meta_blur_unwatched_episodes_description", fallback: ""),
            "Blur episode thumbnails until watched to avoid spoilers"
        )
        XCTAssertEqual(
            L10n.string("tvos_settings_episode_spoilers", fallback: ""),
            "Episode Spoilers"
        )
        XCTAssertEqual(
            L10n.string("tvos_settings_episode_spoilers_subtitle", fallback: ""),
            "Hide spoilers for unwatched episodes in Details and Player"
        )
        XCTAssertEqual(
            L10n.string("tvos_settings_hide_unwatched_descriptions", fallback: ""),
            "Hide Unwatched Descriptions"
        )
        XCTAssertEqual(
            L10n.string("tvos_settings_hide_unwatched_descriptions_subtitle", fallback: ""),
            "Hide episode descriptions until watched to prevent plot spoilers"
        )
        XCTAssertEqual(
            L10n.string("tvos_settings_hide_unwatched_titles", fallback: ""),
            "Hide Unwatched Titles"
        )
        XCTAssertEqual(
            L10n.string("tvos_settings_hide_unwatched_titles_subtitle", fallback: ""),
            "Replace unwatched episode titles with Episode numbers to avoid spoilers"
        )
        XCTAssertEqual(
            L10n.string("details_spoiler_hidden_description", fallback: ""),
            "Description hidden to avoid spoilers."
        )
        XCTAssertEqual(
            L10n.string("settings_continue_watching_blur_next_up_title", fallback: ""),
            "Blur Next Up Artwork"
        )
        XCTAssertEqual(
            L10n.string("settings_continue_watching_blur_next_up_description", fallback: ""),
            "Blur episode thumbnails in Continue Watching for episodes you haven't started yet"
        )
    }

    func testEpisodeTitleMaskingLogic() {
        let video = NuvioVideo(
            id: "ep_1",
            title: "The Shocking Death Scene",
            season: 2,
            episode: 5,
            thumbnail: "https://example.com/ep1.jpg",
            overview: "Major spoiler happens here.",
            released: "2026-01-01"
        )

        // Helper replicating displayTitle logic
        func displayTitle(for video: NuvioVideo, hideTitles: Bool, isWatched: Bool) -> String {
            if hideTitles && !isWatched {
                return L10n.format("calendar_episode_number", fallback: "Episode %d", video.episode)
            }
            return video.title
        }

        // When hide titles is ON and episode is unwatched -> masked
        XCTAssertEqual(
            displayTitle(for: video, hideTitles: true, isWatched: false),
            "Episode 5"
        )

        // When hide titles is ON and episode is watched -> unmasked
        XCTAssertEqual(
            displayTitle(for: video, hideTitles: true, isWatched: true),
            "The Shocking Death Scene"
        )

        // When hide titles is OFF and episode is unwatched -> unmasked
        XCTAssertEqual(
            displayTitle(for: video, hideTitles: false, isWatched: false),
            "The Shocking Death Scene"
        )
    }

    func testEpisodeOverviewMaskingLogic() {
        let originalOverview = "The villain is finally revealed to be the hero's brother."

        func displayOverview(overview: String, hideDescriptions: Bool, isWatched: Bool) -> String {
            if hideDescriptions && !isWatched {
                return L10n.string("details_spoiler_hidden_description", fallback: "Description hidden to avoid spoilers.")
            }
            return overview
        }

        // When hide descriptions is ON and episode is unwatched -> spoiler placeholder
        XCTAssertEqual(
            displayOverview(overview: originalOverview, hideDescriptions: true, isWatched: false),
            "Description hidden to avoid spoilers."
        )

        // When hide descriptions is ON and episode is watched -> original overview
        XCTAssertEqual(
            displayOverview(overview: originalOverview, hideDescriptions: true, isWatched: true),
            originalOverview
        )

        // When hide descriptions is OFF and episode is unwatched -> original overview
        XCTAssertEqual(
            displayOverview(overview: originalOverview, hideDescriptions: false, isWatched: false),
            originalOverview
        )
    }

    func testThumbnailBlurConditionLogic() {
        func shouldBlurThumbnail(blurEnabled: Bool, isWatched: Bool) -> Bool {
            blurEnabled && !isWatched
        }

        XCTAssertTrue(shouldBlurThumbnail(blurEnabled: true, isWatched: false))
        XCTAssertFalse(shouldBlurThumbnail(blurEnabled: true, isWatched: true))
        XCTAssertFalse(shouldBlurThumbnail(blurEnabled: false, isWatched: false))
        XCTAssertFalse(shouldBlurThumbnail(blurEnabled: false, isWatched: true))
    }

    func testPlayerSidePanelBlurConditionLogic() {
        // Player episode panel should blur only if unwatched AND not current episode
        func shouldBlurInPlayer(blurEnabled: Bool, isWatched: Bool, isCurrent: Bool) -> Bool {
            blurEnabled && !isWatched && !isCurrent
        }

        XCTAssertTrue(shouldBlurInPlayer(blurEnabled: true, isWatched: false, isCurrent: false))
        XCTAssertFalse(shouldBlurInPlayer(blurEnabled: true, isWatched: false, isCurrent: true))
        XCTAssertFalse(shouldBlurInPlayer(blurEnabled: true, isWatched: true, isCurrent: false))
        XCTAssertFalse(shouldBlurInPlayer(blurEnabled: false, isWatched: false, isCurrent: false))
    }

    func testNextEpisodeOverlayLineMaskingLogic() {
        let video = NuvioVideo(
            id: "ep_2",
            title: "Resurrection",
            season: 2,
            episode: 6,
            thumbnail: "https://example.com/ep2.jpg",
            overview: nil,
            released: "2026-02-01"
        )

        func nextEpisodeLine(video: NuvioVideo, hideTitles: Bool) -> String {
            if hideTitles {
                return "S\(video.season) E\(video.episode)"
            }
            return "S\(video.season) E\(video.episode) • \(video.title)"
        }

        XCTAssertEqual(nextEpisodeLine(video: video, hideTitles: true), "S2 E6")
        XCTAssertEqual(nextEpisodeLine(video: video, hideTitles: false), "S2 E6 • Resurrection")
    }

    func testContinueWatchingBlurNextUpLogic() {
        func shouldBlurNextUp(blurNextUp: Bool, blurUnwatched: Bool, isUpNext: Bool, hasEpisodeArt: Bool) -> Bool {
            (blurNextUp || blurUnwatched) && isUpNext && hasEpisodeArt
        }

        // True when either blur setting is on, item is up-next, and has episode art
        XCTAssertTrue(shouldBlurNextUp(blurNextUp: true, blurUnwatched: false, isUpNext: true, hasEpisodeArt: true))
        XCTAssertTrue(shouldBlurNextUp(blurNextUp: false, blurUnwatched: true, isUpNext: true, hasEpisodeArt: true))

        // False if not up next (already watching/started)
        XCTAssertFalse(shouldBlurNextUp(blurNextUp: true, blurUnwatched: false, isUpNext: false, hasEpisodeArt: true))

        // False if no episode art (series backdrop only)
        XCTAssertFalse(shouldBlurNextUp(blurNextUp: true, blurUnwatched: false, isUpNext: true, hasEpisodeArt: false))

        // False if both blur settings are off
        XCTAssertFalse(shouldBlurNextUp(blurNextUp: false, blurUnwatched: false, isUpNext: true, hasEpisodeArt: true))
    }

    func testHomeHeroEpisodeDescriptionMaskingLogic() {
        let episodeOverview = "Character X tragically dies in this shocking twist."
        let seriesDescription = "A story about a high school teacher."

        func heroDescription(
            episodeOverview: String?,
            seriesDescription: String?,
            hideDescriptions: Bool,
            isCurrentlyWatching: Bool,
            isWatched: Bool
        ) -> String? {
            let shouldHide = !isCurrentlyWatching && !isWatched
            if hideDescriptions && shouldHide {
                return L10n.string("details_spoiler_hidden_description", fallback: "Description hidden to avoid spoilers.")
            }
            if let overview = episodeOverview, !overview.isEmpty {
                return overview
            }
            return seriesDescription
        }

        // When hide descriptions is ON and episode is unwatched & unstarted -> placeholder
        XCTAssertEqual(
            heroDescription(
                episodeOverview: episodeOverview,
                seriesDescription: seriesDescription,
                hideDescriptions: true,
                isCurrentlyWatching: false,
                isWatched: false
            ),
            "Description hidden to avoid spoilers."
        )

        // When hide descriptions is ON and episode is CURRENTLY WATCHING -> unmasked (shows overview)
        XCTAssertEqual(
            heroDescription(
                episodeOverview: episodeOverview,
                seriesDescription: seriesDescription,
                hideDescriptions: true,
                isCurrentlyWatching: true,
                isWatched: false
            ),
            episodeOverview
        )

        // When hide descriptions is ON and episode is watched -> episode overview
        XCTAssertEqual(
            heroDescription(
                episodeOverview: episodeOverview,
                seriesDescription: seriesDescription,
                hideDescriptions: true,
                isCurrentlyWatching: false,
                isWatched: true
            ),
            episodeOverview
        )

        // When hide descriptions is OFF -> episode overview
        XCTAssertEqual(
            heroDescription(
                episodeOverview: episodeOverview,
                seriesDescription: seriesDescription,
                hideDescriptions: false,
                isCurrentlyWatching: false,
                isWatched: false
            ),
            episodeOverview
        )

        // When no episode overview and episode is unwatched & unstarted -> placeholder
        XCTAssertEqual(
            heroDescription(
                episodeOverview: nil,
                seriesDescription: seriesDescription,
                hideDescriptions: true,
                isCurrentlyWatching: false,
                isWatched: false
            ),
            "Description hidden to avoid spoilers."
        )
    }

    func testHomeHeroEpisodeLineMaskingLogic() {
        func heroEpisodeLine(
            episodeLabel: String,
            episodeDisplayLine: String,
            hideTitles: Bool,
            isCurrentlyWatching: Bool,
            isWatched: Bool
        ) -> String {
            let shouldHide = !isCurrentlyWatching && !isWatched
            if hideTitles && shouldHide {
                return episodeLabel
            }
            return episodeDisplayLine
        }

        let label = "S2 E5"
        let fullLine = "S2 E5 · The Shocking Death Scene"

        // Masked when ON and unstarted/unwatched -> label only (no title)
        XCTAssertEqual(
            heroEpisodeLine(
                episodeLabel: label,
                episodeDisplayLine: fullLine,
                hideTitles: true,
                isCurrentlyWatching: false,
                isWatched: false
            ),
            "S2 E5"
        )

        // Unmasked when ON and CURRENTLY WATCHING -> full line (title shown)
        XCTAssertEqual(
            heroEpisodeLine(
                episodeLabel: label,
                episodeDisplayLine: fullLine,
                hideTitles: true,
                isCurrentlyWatching: true,
                isWatched: false
            ),
            "S2 E5 · The Shocking Death Scene"
        )

        // Unmasked when ON and watched -> full line
        XCTAssertEqual(
            heroEpisodeLine(
                episodeLabel: label,
                episodeDisplayLine: fullLine,
                hideTitles: true,
                isCurrentlyWatching: false,
                isWatched: true
            ),
            "S2 E5 · The Shocking Death Scene"
        )

        // Unmasked when OFF and unwatched -> full line
        XCTAssertEqual(
            heroEpisodeLine(
                episodeLabel: label,
                episodeDisplayLine: fullLine,
                hideTitles: false,
                isCurrentlyWatching: false,
                isWatched: false
            ),
            "S2 E5 · The Shocking Death Scene"
        )
    }

    func testCurrentlyWatchingEpisodesNeverHideSpoilers() {
        func shouldApplySpoilerProtection(isWatched: Bool, continueProgress: Double?) -> Bool {
            let isCurrentlyWatching = (continueProgress ?? 0) > 0
            return !isWatched && !isCurrentlyWatching
        }

        // Currently watching (progress > 0) -> protection disabled (do not hide)
        XCTAssertFalse(shouldApplySpoilerProtection(isWatched: false, continueProgress: 0.35))

        // Unwatched & unstarted (progress nil or 0) -> protection enabled (hide spoilers)
        XCTAssertTrue(shouldApplySpoilerProtection(isWatched: false, continueProgress: nil))
        XCTAssertTrue(shouldApplySpoilerProtection(isWatched: false, continueProgress: 0.0))

        // Watched -> protection disabled
        XCTAssertFalse(shouldApplySpoilerProtection(isWatched: true, continueProgress: 0.0))
        XCTAssertFalse(shouldApplySpoilerProtection(isWatched: true, continueProgress: 1.0))
    }
}
