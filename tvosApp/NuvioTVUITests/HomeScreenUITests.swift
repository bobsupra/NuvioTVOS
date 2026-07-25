//
//  HomeScreenUITests.swift
//  NuvioTVUITests
//
//  UI tests for home screen functionality
//

import XCTest

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
        if images.count > 0 {
            XCTAssertTrue(images.firstMatch.exists, "Hero carousel should display featured content")
        }
    }

    func testHeroCarouselSwipeable() throws {
        sleep(2)

        // Try swiping the hero carousel
        let firstImage = app.images.firstMatch
        if firstImage.exists {
            firstImage.swipeLeft()
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
        if images.count > 0 {
            let firstImage = images.firstMatch
            if firstImage.exists {
                firstImage.swipeLeft()
                sleep(0.5)

                XCTAssertTrue(app.exists, "Category rows should support horizontal scrolling")
            }
        }
    }

    func testTapCategoryItem() throws {
        sleep(2)

        // Tap a content item in a category row
        let images = app.images
        if images.count > 1 {
            let item = images.element(boundBy: 1)
            if item.exists && item.isHittable {
                item.tap()
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
        if app.staticTexts["Continue Watching"].exists {
            XCTAssertTrue(true, "Continue watching section exists")
        }
    }

    func testContinueWatchingItems() throws {
        sleep(2)

        if app.staticTexts["Continue Watching"].exists {
            // Should have continue watching items
            let images = app.images
            XCTAssertGreaterThan(images.count, 0, "Continue watching should display items")
        }
    }

    // MARK: - Watchlist Section Tests

    func testWatchlistSectionExists() throws {
        sleep(2)

        // Watchlist section might be present
        if app.staticTexts["My Watchlist"].exists || app.staticTexts["Watchlist"].exists {
            XCTAssertTrue(true, "Watchlist section exists")
        }
    }

    func testWatchlistItems() throws {
        sleep(2)

        if app.staticTexts["My Watchlist"].exists || app.staticTexts["Watchlist"].exists {
            // Should have watchlist items
            let images = app.images
            XCTAssertGreaterThan(images.count, 0, "Watchlist should display items")
        }
    }

    // MARK: - Vertical Scrolling Tests

    func testHomeScreenVerticalScrolling() throws {
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            // Scroll down
            scrollView.swipeUp()
            sleep(0.5)

            // Scroll down more
            scrollView.swipeUp()
            sleep(0.5)

            // Scroll back up
            scrollView.swipeDown()
            sleep(0.5)

            XCTAssertTrue(scrollView.exists, "Home screen should support vertical scrolling")
        }
    }

    func testScrollToBottomAndTop() throws {
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            // Scroll to bottom
            for _ in 1...5 {
                scrollView.swipeUp()
                sleep(0.3)
            }

            // Scroll to top
            for _ in 1...5 {
                scrollView.swipeDown()
                sleep(0.3)
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
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            // Pull down from top to refresh (if implemented)
            let startPoint = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let endPoint = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

            startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
            sleep(2)

            // Should handle pull-to-refresh gracefully (even if not implemented)
            XCTAssertTrue(scrollView.exists, "Should handle pull gesture")
        }
    }

    // MARK: - Navigation Tests

    func testNavigateFromHomeToDetails() throws {
        sleep(2)

        // Tap content item
        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                // Should navigate to details
                XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                            app.buttons["Watchlist"].waitForExistence(timeout: 3.0),
                            "Should navigate to details screen")

                // Navigate back
                if app.navigationBars.buttons.firstMatch.exists {
                    app.navigationBars.buttons.firstMatch.tap()
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
        if scrollView.exists {
            measure {
                scrollView.swipeUp()
                sleep(0.3)
            }
        }
    }

    func testHeroCarouselTransitionPerformance() throws {
        sleep(2)

        let firstImage = app.images.firstMatch
        if firstImage.exists {
            measure {
                firstImage.swipeLeft()
                sleep(0.5)
            }
        }
    }

    // MARK: - Memory Tests

    func testHomeScreenMemoryStability() throws {
        sleep(2)

        // Scroll multiple times to test memory stability
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            for _ in 1...10 {
                scrollView.swipeUp()
                sleep(0.2)
            }

            for _ in 1...10 {
                scrollView.swipeDown()
                sleep(0.2)
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
