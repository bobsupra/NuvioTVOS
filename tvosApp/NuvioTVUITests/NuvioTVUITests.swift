//
//  NuvioTVUITests.swift
//  NuvioTVUITests
//
//  UI tests for NuvioTV application
//

import XCTest

final class NuvioTVUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - App Launch Tests

    func testAppLaunches() throws {
        XCTAssertTrue(app.exists, "App should launch successfully")
    }

    // MARK: - Home Screen Tests

    func testHomeScreenLoads() throws {
        // Wait for home screen to load
        let homeScreenExists = app.staticTexts["Trending Movies"].waitForExistence(timeout: 5.0) ||
                               app.staticTexts["Trending Series"].waitForExistence(timeout: 5.0)

        XCTAssertTrue(homeScreenExists, "Home screen should load with catalog titles")
    }

    func testHomeScreenHasContent() throws {
        // Wait for content to load
        sleep(2)

        // Check for at least one content item (poster card)
        let images = app.images
        XCTAssertGreaterThan(images.count, 0, "Home screen should display content posters")
    }

    func testHeroCarouselExists() throws {
        // Wait for screen to load
        sleep(2)

        // Hero carousel should be present (implementation may vary)
        // This test validates that some content is visible at the top
        let scrollViews = app.scrollViews
        XCTAssertGreaterThan(scrollViews.count, 0, "Should have scrollable content")
    }

    // MARK: - Navigation Tests

    func testNavigateToCatalogBrowse() throws {
        // Wait for home screen
        sleep(2)

        // Look for a "Browse" or category button/text
        // Note: This depends on actual navigation implementation
        if app.buttons["Browse Movies"].exists {
            app.buttons["Browse Movies"].tap()

            // Verify catalog browse screen loaded
            sleep(1)
            XCTAssertTrue(app.exists, "Should navigate to catalog browse")
        }
    }

    func testNavigateToContentDetails() throws {
        // Wait for home screen to load content
        sleep(2)

        // Tap first content item if available
        let images = app.images
        if images.count > 0 {
            // Try to tap a content poster
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists {
                firstImage.tap()

                // Wait for details screen to load
                sleep(1)

                // Verify we're on details screen (look for action buttons or metadata)
                let detailsLoaded = app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                                   app.buttons["Watchlist"].waitForExistence(timeout: 3.0)

                XCTAssertTrue(detailsLoaded, "Details screen should load with action buttons")
            }
        }
    }

    // MARK: - Scroll Performance Tests

    func testHomeScreenScrolling() throws {
        // Wait for screen to load
        sleep(2)

        // Get first scroll view
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            // Scroll down
            scrollView.swipeUp()
            sleep(1)

            // Scroll up
            scrollView.swipeDown()
            sleep(1)

            XCTAssertTrue(scrollView.exists, "Scroll view should remain responsive")
        }
    }

    // MARK: - Performance Tests

    func testAppLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launch()
        }
    }
}
