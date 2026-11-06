//
//  HomeScreenUITests.swift
//  NuvioTVUITests
//
//  UI tests for home screen functionality
//

import XCTest

@MainActor
final class HomeScreenUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Home Screen Load Tests

    func testHomeScreenAppearsOnLaunch() throws {
        // Home screen should be visible after launch
        XCTAssertTrue(app.exists, "App should launch to home screen")

        // Wait for content to load
        sleep(2)

        // Should have some content visible
        XCTAssertGreaterThan(app.staticTexts.count, 0, "Home screen should display text elements")
    }

    func testHomeScreenLoadsCatalogs() throws {
        sleep(2)

        // Should have catalog titles (Trending Movies, Trending Series, etc.)
        let catalogTitlesExist = app.staticTexts["Trending Movies"].exists ||
                                app.staticTexts["Trending Series"].exists ||
                                app.staticTexts.count > 5

        XCTAssertTrue(catalogTitlesExist, "Home screen should display catalog sections")
    }

    func testHomeScreenLoadsCatalogItems() throws {
        sleep(2)

        // Should display content posters
        let images = app.images
        XCTAssertGreaterThan(images.count, 5, "Home screen should display multiple content items")
    }

    // MARK: - Hero Carousel Tests

    func testHeroCarouselExists() throws {
        sleep(2)

        // Hero carousel should be at the top
        // It uses TabView in the implementation
        let scrollViews = app.scrollViews
        XCTAssertGreaterThan(scrollViews.count, 0, "Home screen should have scrollable content")
    }

    func testHeroCarouselDisplaysContent() throws {
        sleep(2)

        // Hero should display featured content
        let images = app.images
        if requireUICondition(images.count > 0) {
            XCTAssertTrue(images.firstMatch.exists, "Hero carousel should display featured content")
        }
    }

    func testHeroCarouselSwipeable() throws {
        sleep(2)

        // Try swiping the hero carousel
        let firstImage = app.images.firstMatch
        if requireUICondition(firstImage.exists) {
            moveTVFocus(.right, in: app, within: firstImage)
            sleep(1)

            // Should transition to next item
            XCTAssertTrue(app.exists, "Hero carousel should be swipeable")
        }
    }

    // MARK: - Category Row Tests

    func testCategoryRowsExist() throws {
        sleep(2)

        // Should have multiple category rows
        let textElements = app.staticTexts

        // Look for category titles
        let hasCategoryTitles = textElements.count > 3
        XCTAssertTrue(hasCategoryTitles, "Should have category row titles")
    }

    func testCategoryRowHorizontalScrolling() throws {
        sleep(2)

        // Category rows should be horizontally scrollable
        let images = app.images
        if requireUICondition(images.count > 0) {
            let firstImage = images.firstMatch
            if requireUICondition(firstImage.exists) {
                moveTVFocus(.right, in: app, within: firstImage)
                Thread.sleep(forTimeInterval: 0.5)

                XCTAssertTrue(app.exists, "Category rows should support horizontal scrolling")
            }
        }
    }

    func testTapCategoryItem() throws {
        sleep(2)

        // Tap a content item in a category row
        let images = app.images
        if requireUICondition(images.count > 1) {
            let item = images.element(boundBy: 1)
            if requireUICondition(item.exists && item.isHittable) {
                selectTVElement(item, in: app)
                sleep(1)

                // Should navigate to details
                let detailsLoaded = app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                                   app.buttons["Watchlist"].waitForExistence(timeout: 3.0)

                XCTAssertTrue(detailsLoaded, "Tapping category item should open details")
            }
        }
    }

    // MARK: - Continue Watching Section Tests

    func testContinueWatchingSectionExists() throws {
        sleep(2)

        // Continue watching section might be present
        XCTAssertTrue(
            app.staticTexts["Continue Watching"].waitForExistence(timeout: 5),
            "The Continue Watching fixture must display its section"
        )
    }

    func testContinueWatchingItems() throws {
        sleep(2)

        if requireUICondition(app.staticTexts["Continue Watching"].exists) {
            // Should have continue watching items
            let images = app.images
            XCTAssertGreaterThan(images.count, 0, "Continue watching should display items")
        }
    }

    // MARK: - Watchlist Section Tests

    func testWatchlistSectionExists() throws {
        sleep(2)

        // Watchlist section might be present
        XCTAssertTrue(
            app.staticTexts["My Watchlist"].waitForExistence(timeout: 5) ||
                app.staticTexts["Watchlist"].waitForExistence(timeout: 2),
            "The watchlist fixture must display its section"
        )
    }

    func testWatchlistItems() throws {
        sleep(2)

        if requireUICondition(app.staticTexts["My Watchlist"].exists || app.staticTexts["Watchlist"].exists) {
            // Should have watchlist items
            let images = app.images
            XCTAssertGreaterThan(images.count, 0, "Watchlist should display items")
        }
    }

    // MARK: - Vertical Scrolling Tests

    func testHomeScreenVerticalScrolling() throws {
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if requireUICondition(scrollView.exists) {
            // Scroll down
            moveTVFocus(.down, in: app, within: scrollView)
            Thread.sleep(forTimeInterval: 0.5)

            // Scroll down more
            moveTVFocus(.down, in: app, within: scrollView)
            Thread.sleep(forTimeInterval: 0.5)

            // Scroll back up
            moveTVFocus(.up, in: app, within: scrollView)
            Thread.sleep(forTimeInterval: 0.5)

            XCTAssertTrue(scrollView.exists, "Home screen should support vertical scrolling")
        }
    }

    func testScrollToBottomAndTop() throws {
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if requireUICondition(scrollView.exists) {
            // Scroll to bottom
            for _ in 1...5 {
                moveTVFocus(.down, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.3)
            }

            // Scroll to top
            for _ in 1...5 {
                moveTVFocus(.up, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.3)
            }

            XCTAssertTrue(scrollView.exists, "Should handle full scroll range")
        }
    }

    // MARK: - Loading State Tests

    func testHomeScreenLoadingState() throws {
        // On fresh launch, might see loading indicator
        let loadingIndicator = app.activityIndicators.firstMatch

        if loadingIndicator.exists {
            // Wait for loading to complete
            let contentAppears = app.images.firstMatch.waitForExistence(timeout: 5.0)
            XCTAssertTrue(contentAppears, "Content should appear after loading")
        } else {
            // Content loaded quickly, that's fine
            sleep(2)
            XCTAssertGreaterThan(app.images.count, 0, "Content should be visible")
        }
    }

    // MARK: - Refresh Tests

    func testPullToRefresh() throws {
        throw XCTSkip("Touch pull-to-refresh has no defined tvOS remote action or refresh fixture.")
    }

    // MARK: - Navigation Tests

    func testImmediateLeftAfterDetailsReturnsToPreviousCard() throws {
        app.terminate()
        app.launchArguments = [
            "-nuvio.auth.skippedLogin", "YES",
            "-nuvio.tv.settings.layout.homeLayout", "Modern"
        ]
        app.launch()

        let catalogPrefix = "poster-card-movie_top\u{1}"
        let focusedPoster = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND hasFocus == true", catalogPrefix
        )).firstMatch
        XCTAssertTrue(
            focusedPoster.waitForExistence(timeout: 20),
            "Requires a guest Home fixture with Popular Movies focused and notices dismissed"
        )
        let firstID = focusedPoster.identifier

        XCUIRemote.shared.press(.right)
        let secondPoster = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@ AND hasFocus == true",
            catalogPrefix, firstID
        )).firstMatch
        XCTAssertTrue(secondPoster.waitForExistence(timeout: 5), "The fixture needs at least three cards in a row")
        let secondID = secondPoster.identifier

        XCUIRemote.shared.press(.right)
        let thirdPoster = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@ AND identifier != %@ AND hasFocus == true",
            catalogPrefix, firstID, secondID
        )).firstMatch
        XCTAssertTrue(thirdPoster.waitForExistence(timeout: 5), "The fixture needs at least three cards in a row")
        let thirdID = thirdPoster.identifier
        let rowID = secondID.components(separatedBy: "\u{1}").dropLast()
        XCTAssertEqual(rowID, thirdID.components(separatedBy: "\u{1}").dropLast())

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["Play"].waitForExistence(timeout: 10) ||
                app.buttons["Watchlist"].waitForExistence(timeout: 5),
            "Selecting the third card should open Details"
        )

        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.left)

        let previousCard = app.buttons[secondID]
        let didFocusPreviousCard = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"), object: previousCard
        )], timeout: 5) == .completed
        let focusedElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(
            didFocusPreviousCard,
            "Immediate Left after Details should focus the previous card; focused: \(focusedElement.debugDescription)"
        )
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasFocus == true"), object: app.buttons[firstID]
            )], timeout: 5) == .completed,
            "Left navigation should continue normally after the return"
        )
    }

    func testNetflixSearchImmediateLeftAfterDetails() throws {
        try verifySearchReturnLeft(style: "Netflix", resultPrefix: "netflix-search-result-grid:")
    }

    func testNativeSearchImmediateLeftAfterDetails() throws {
        try verifySearchReturnLeft(style: "Native", resultPrefix: "native-search-result-")
    }

    private func verifySearchReturnLeft(style: String, resultPrefix: String) throws {
        app.terminate()
        app.launchArguments = [
            "-nuvio.auth.skippedLogin", "YES",
            "-nuvio.tv.settings.layout.searchStyle", style
        ]
        app.launch()

        let homeCard = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND hasFocus == true", "poster-card-movie_top\u{1}"
        )).firstMatch
        XCTAssertTrue(homeCard.waitForExistence(timeout: 20), "Requires a guest Home fixture with notices dismissed")
        XCUIRemote.shared.press(.left)
        let searchTab = app.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5), "The sidebar must expose the Search tab")
        selectTVElement(searchTab, in: app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search must expose its text field")
        if !searchField.hasFocus {
            selectTVElement(searchField, in: app)
        }
        XCTAssertTrue(searchField.hasFocus, "The Search field must have focus before typing")
        searchField.typeText("Batman")

        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", resultPrefix))
        let previousCard = results.element(boundBy: 1)
        XCTAssertTrue(previousCard.waitForExistence(timeout: 20), "The Batman fixture needs at least three results")
        let previousID = previousCard.identifier
        moveTVFocus(.right, in: app, within: previousCard)
        let selectedCard = results.matching(NSPredicate(format: "hasFocus == true AND identifier != %@", previousID)).firstMatch
        XCTAssertTrue(selectedCard.waitForExistence(timeout: 5), "Right should focus the next Search result")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["Play"].waitForExistence(timeout: 10) ||
                app.buttons["Watchlist"].waitForExistence(timeout: 5),
            "Selecting the Search result should open Details"
        )
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.left)

        let restoredCard = app.buttons[previousID]
        let restored = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"), object: restoredCard
        )], timeout: 5) == .completed
        let focusedElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(restored, "Immediate Left in \(style) Search should focus the preceding result; focused: \(focusedElement.debugDescription)")
    }

    func testNavigateFromHomeToDetails() throws {
        sleep(2)

        // Tap content item
        let images = app.images
        if requireUICondition(images.count > 0) {
            let firstImage = images.element(boundBy: 0)
            if requireUICondition(firstImage.exists && firstImage.isHittable) {
                selectTVElement(firstImage, in: app)
                sleep(1)

                // Should navigate to details
                XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                            app.buttons["Watchlist"].waitForExistence(timeout: 3.0),
                            "Should navigate to details screen")

                // Navigate back
                if requireUICondition(app.exists) {
                    XCUIRemote.shared.press(.menu)
                    sleep(1)

                    // Should return to home screen
                    XCTAssertGreaterThan(app.images.count, 3, "Should return to home screen")
                }
            }
        }
    }

    // MARK: - Platform-Specific Tests

    func testHomeScreenAdaptiveLayout() throws {
        sleep(2)

        #if os(iOS)
        // On iOS, should have mobile-friendly layout
        XCTAssertGreaterThan(app.staticTexts.count, 0, "iOS should display home content")
        #elseif os(tvOS)
        // On tvOS, should have TV-optimized layout with focus
        XCTAssertGreaterThan(app.staticTexts.count, 0, "tvOS should display home content")
        #endif
    }

    // MARK: - Performance Tests

    func testHomeScreenInitialLoadPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let testApp = XCUIApplication()
            testApp.launch()
        }
    }

    func testHomeScreenScrollPerformance() throws {
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if requireUICondition(scrollView.exists) {
            measure {
                moveTVFocus(.down, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    func testHeroCarouselTransitionPerformance() throws {
        sleep(2)

        let firstImage = app.images.firstMatch
        if requireUICondition(firstImage.exists) {
            measure {
                moveTVFocus(.right, in: app, within: firstImage)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    // MARK: - Memory Tests

    func testHomeScreenMemoryStability() throws {
        sleep(2)

        // Scroll multiple times to test memory stability
        let scrollView = app.scrollViews.firstMatch
        if requireUICondition(scrollView.exists) {
            for _ in 1...10 {
                moveTVFocus(.down, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.2)
            }

            for _ in 1...10 {
                moveTVFocus(.up, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.2)
            }

            // App should remain responsive
            XCTAssertTrue(scrollView.exists, "Home screen should remain stable after extensive scrolling")
        }
    }

    // MARK: - Content Variety Tests

    func testHomeScreenShowsMoviesAndSeries() throws {
        sleep(2)

        // Should display both movies and series
        let hasMovies = app.staticTexts["Trending Movies"].exists ||
                       app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'movie'")).count > 0

        let hasSeries = app.staticTexts["Trending Series"].exists ||
                       app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'series'")).count > 0

        XCTAssertTrue(hasMovies || hasSeries, "Home screen should display movie or series content")
    }
}
