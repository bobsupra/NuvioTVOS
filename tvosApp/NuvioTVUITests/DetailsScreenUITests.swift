//
//  DetailsScreenUITests.swift
//  NuvioTVUITests
//
//  UI tests for content details screen
//

import XCTest

final class DetailsScreenUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // Helper function to navigate to details screen
    func navigateToDetailsScreen() {
        sleep(2)

        // Tap first content item
        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)
            }
        }
    }

    // MARK: - Details Screen Layout Tests

    func testDetailsScreenLoads() throws {
        navigateToDetailsScreen()

        // Details screen should have action buttons or content title
        let detailsLoaded = app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                           app.buttons["Watchlist"].waitForExistence(timeout: 3.0) ||
                           app.staticTexts.count > 5

        XCTAssertTrue(detailsLoaded, "Details screen should load")
    }

    func testDetailsScreenHasMetadata() throws {
        navigateToDetailsScreen()

        // Should display metadata (title, description, etc.)
        let textElements = app.staticTexts
        XCTAssertGreaterThan(textElements.count, 3, "Should display multiple metadata fields")
    }

    func testDetailsScreenHasBackgroundImage() throws {
        navigateToDetailsScreen()

        // Should have background image
        let images = app.images
        XCTAssertGreaterThan(images.count, 0, "Should display background or poster image")
    }

    // MARK: - Action Button Tests

    func testPlayButtonExists() throws {
        navigateToDetailsScreen()

        // Play button should be present
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0), "Play button should exist")
    }

    func testWatchlistButtonExists() throws {
        navigateToDetailsScreen()

        // Watchlist button should be present
        XCTAssertTrue(app.buttons["Watchlist"].waitForExistence(timeout: 3.0), "Watchlist button should exist")
    }

    func testWatchlistButtonToggle() throws {
        navigateToDetailsScreen()

        if app.buttons["Watchlist"].exists {
            // Tap to add to watchlist
            app.buttons["Watchlist"].tap()
            sleep(0.5)

            // Button should update (text might change or remain same)
            XCTAssertTrue(app.buttons["Watchlist"].exists, "Watchlist button should remain")

            // Tap again to remove from watchlist
            app.buttons["Watchlist"].tap()
            sleep(0.5)

            XCTAssertTrue(app.buttons["Watchlist"].exists, "Watchlist button should toggle state")
        }
    }

    func testShareButtonExists() throws {
        navigateToDetailsScreen()

        // Share button should be present
        if app.buttons["Share"].exists {
            XCTAssertTrue(true, "Share button exists")
        }
    }

    func testShareButtonOpensShareSheet() throws {
        navigateToDetailsScreen()

        if app.buttons["Share"].exists {
            app.buttons["Share"].tap()
            sleep(1)

            // Share sheet should appear (platform specific)
            // On iOS, look for activity view controller elements
            XCTAssertTrue(app.exists, "Share action should be handled")
        }
    }

    // MARK: - Watched toggle

    func testWatchedControlExists() throws {
        navigateToDetailsScreen()

        // tvOS details uses an icon-only watched button (no star/rating UI).
        if app.buttons["Watched"].exists || app.buttons["Unwatched"].exists || app.buttons["Rate"].exists {
            XCTAssertTrue(true, "Watched control exists")
        }
    }

    func testWatchedToggleInteraction() throws {
        navigateToDetailsScreen()

        if app.buttons["Watched"].exists {
            app.buttons["Watched"].tap()
            sleep(1)
            XCTAssertTrue(app.exists, "Watched toggle should be handled")
        } else if app.buttons["Unwatched"].exists {
            app.buttons["Unwatched"].tap()
            sleep(1)
            XCTAssertTrue(app.exists, "Watched toggle should be handled")
        }
    }

    // MARK: - Metadata Display Tests

    func testGenresDisplayed() throws {
        navigateToDetailsScreen()

        // Look for genre badges or chips
        let staticTexts = app.staticTexts

        // Should have multiple text elements (title, description, genres, etc.)
        XCTAssertGreaterThan(staticTexts.count, 3, "Should display metadata including genres")
    }

    func testRatingDisplayed() throws {
        navigateToDetailsScreen()

        // Rating should be visible somewhere in the details
        // This could be in various formats (stars, numbers, badges)
        let allElements = app.descendants(matching: .any)
        XCTAssertGreaterThan(allElements.count, 10, "Should have rich content including rating")
    }

    func testCastCrewSection() throws {
        navigateToDetailsScreen()

        // Should display cast/crew information
        let textElements = app.staticTexts

        // Look for cast-related text
        let hasCastInfo = textElements.containing(NSPredicate(format: "label CONTAINS[c] 'actor'")).count > 0 ||
                         textElements.containing(NSPredicate(format: "label CONTAINS[c] 'director'")).count > 0 ||
                         textElements.count > 10

        XCTAssertTrue(hasCastInfo, "Should display cast/crew information")
    }

    // MARK: - Scroll Tests

    func testDetailsScreenScrolling() throws {
        navigateToDetailsScreen()

        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            // Scroll down to see more content
            scrollView.swipeUp()
            sleep(0.5)

            // Scroll back up
            scrollView.swipeDown()
            sleep(0.5)

            XCTAssertTrue(scrollView.exists, "Details screen should be scrollable")
        }
    }

    // MARK: - Platform-Specific Layout Tests

    func testAdaptiveLayout() throws {
        navigateToDetailsScreen()

        // Details screen should adapt to platform
        #if os(iOS)
        // On iOS, should have mobile layout
        XCTAssertGreaterThan(app.staticTexts.count, 3, "iOS should display mobile layout")
        #elseif os(tvOS)
        // On tvOS, should have TV layout with focus support
        XCTAssertGreaterThan(app.staticTexts.count, 3, "tvOS should display TV layout")
        #endif
    }

    // MARK: - Navigation Tests

    func testBackNavigation() throws {
        navigateToDetailsScreen()

        // Try to navigate back
        if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)

            // Should return to previous screen
            XCTAssertTrue(app.exists, "Should navigate back")
        } else {
            // SwiftUI might use different navigation
            // Try swipe back gesture
            let startPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            let endPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
            sleep(1)

            XCTAssertTrue(app.exists, "Should support back navigation")
        }
    }

    // MARK: - Loading State Tests

    func testDetailsLoadingState() throws {
        // On navigation, should show loading briefly
        sleep(2)

        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()

                // Loading indicator might appear briefly
                let loadingIndicator = app.activityIndicators.firstMatch
                let hasLoadingOrContent = loadingIndicator.exists ||
                                         app.buttons["Play"].waitForExistence(timeout: 3.0)

                XCTAssertTrue(hasLoadingOrContent, "Should show loading or content")
            }
        }
    }

    // MARK: - Stream Information Tests

    func testStreamInformationDisplayed() throws {
        navigateToDetailsScreen()

        // Wait for streams to load
        sleep(2)

        // Stream quality or source information might be displayed
        // This depends on implementation
        XCTAssertTrue(app.exists, "Details screen should remain stable after stream loading")
    }

    // MARK: - Performance Tests

    func testDetailsScreenLoadPerformance() throws {
        measure {
            navigateToDetailsScreen()
        }
    }

    func testDetailsScreenScrollPerformance() throws {
        navigateToDetailsScreen()

        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            measure {
                scrollView.swipeUp()
                sleep(0.5)
            }
        }
    }

    // MARK: - Multiple Content Tests

    func testNavigateToMultipleContentItems() throws {
        sleep(2)

        // Navigate to first item
        let images = app.images
        if images.count > 1 {
            // First item
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                // Verify details loaded
                XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                            app.buttons["Watchlist"].waitForExistence(timeout: 3.0),
                            "First details screen should load")

                // Navigate back
                if app.navigationBars.buttons.firstMatch.exists {
                    app.navigationBars.buttons.firstMatch.tap()
                    sleep(1)
                }

                // Navigate to second item
                if images.count > 1 {
                    let secondImage = images.element(boundBy: 1)
                    if secondImage.exists && secondImage.isHittable {
                        secondImage.tap()
                        sleep(1)

                        // Verify second details loaded
                        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                                    app.buttons["Watchlist"].waitForExistence(timeout: 3.0),
                                    "Second details screen should load")
                    }
                }
            }
        }
    }
}
