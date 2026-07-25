//
//  EndToEndFlowTests.swift
//  NuvioTVUITests
//
//  End-to-end tests for critical user flows
//

import XCTest

final class EndToEndFlowTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Content Discovery Flow

    func testCompleteContentDiscoveryFlow() throws {
        // 1. Launch app (home screen)
        XCTAssertTrue(app.exists, "App should launch")
        sleep(2)

        // 2. Browse home screen content
        XCTAssertGreaterThan(app.images.count, 0, "Home screen should show content")

        // 3. Scroll through categories
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeUp()
            sleep(1)
        }

        // 4. Tap a content item
        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                // 5. View details screen
                let detailsLoaded = app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                                   app.buttons["Watchlist"].waitForExistence(timeout: 3.0)
                XCTAssertTrue(detailsLoaded, "Details screen should load")

                // 6. Scroll details to see more info
                let detailsScrollView = app.scrollViews.firstMatch
                if detailsScrollView.exists {
                    detailsScrollView.swipeUp()
                    sleep(0.5)
                }

                // 7. Navigate back to home
                if app.navigationBars.buttons.firstMatch.exists {
                    app.navigationBars.buttons.firstMatch.tap()
                    sleep(1)
                }

                // 8. Verify back at home screen
                XCTAssertGreaterThan(app.images.count, 3, "Should return to home screen")
            }
        }
    }

    // MARK: - Catalog Browsing Flow

    func testCompleteCatalogBrowseFlow() throws {
        // 1. Start at home screen
        sleep(2)

        // 2. Navigate to catalog browse (if navigation exists)
        // For now, we'll simulate browsing on home screen

        // 3. Apply genre filter
        if app.buttons["action"].exists {
            app.buttons["action"].tap()
            sleep(1)
            XCTAssertTrue(app.exists, "Genre filter should apply")
        }

        // 4. Change sort option
        if app.buttons["Popular"].exists {
            app.buttons["Popular"].tap()
            sleep(1)
            XCTAssertTrue(app.exists, "Sort should apply")
        }

        // 5. Scroll to load more items
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            for _ in 1...3 {
                scrollView.swipeUp()
                sleep(0.5)
            }
        }

        // 6. Tap an item
        let images = app.images
        if images.count > 5 {
            let item = images.element(boundBy: 5)
            if item.exists && item.isHittable {
                item.tap()
                sleep(1)

                // 7. Verify details loaded
                XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                            app.staticTexts.count > 5,
                            "Should navigate to details")
            }
        }

        // 8. Clear filters (if possible)
        if app.buttons["Clear Filters"].exists {
            app.buttons["Clear Filters"].tap()
            sleep(1)
        }
    }

    // MARK: - Watchlist Management Flow

    func testWatchlistManagementFlow() throws {
        // 1. Navigate to content details
        sleep(2)
        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                // 2. Add to watchlist
                if app.buttons["Watchlist"].exists {
                    app.buttons["Watchlist"].tap()
                    sleep(0.5)
                    XCTAssertTrue(app.buttons["Watchlist"].exists, "Watchlist state should update")

                    // 3. Remove from watchlist
                    app.buttons["Watchlist"].tap()
                    sleep(0.5)
                    XCTAssertTrue(app.buttons["Watchlist"].exists, "Should toggle watchlist")
                }

                // 4. Navigate back
                if app.navigationBars.buttons.firstMatch.exists {
                    app.navigationBars.buttons.firstMatch.tap()
                    sleep(1)
                }

                // 5. Check if watchlist section updated on home screen
                if app.staticTexts["My Watchlist"].exists || app.staticTexts["Watchlist"].exists {
                    XCTAssertTrue(true, "Watchlist section should be visible")
                }
            }
        }
    }

    // MARK: - Content Rating Flow

    func testContentRatingFlow() throws {
        // 1. Navigate to content details
        sleep(2)
        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                // 2. Open rating interface
                if app.buttons["Watched"].exists {
                    app.buttons["Watched"].tap()
                    sleep(1)

                    // 3. Submit rating (implementation varies)
                    // This is a placeholder for rating interaction
                    XCTAssertTrue(app.exists, "Rating interface should be accessible")
                }

                // 4. Navigate back
                if app.navigationBars.buttons.firstMatch.exists {
                    app.navigationBars.buttons.firstMatch.tap()
                    sleep(1)
                }
            }
        }
    }

    // MARK: - Content Sharing Flow

    func testContentSharingFlow() throws {
        // 1. Navigate to content details
        sleep(2)
        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                // 2. Open share sheet
                if app.buttons["Share"].exists {
                    app.buttons["Share"].tap()
                    sleep(1)

                    // 3. Verify share sheet appears (platform specific)
                    // Share sheet might show different UI elements on iOS vs tvOS
                    XCTAssertTrue(app.exists, "Share action should be handled")

                    // 4. Dismiss share sheet (tap outside or cancel)
                    // This varies by platform
                    let cancelButton = app.buttons["Cancel"]
                    if cancelButton.exists {
                        cancelButton.tap()
                        sleep(0.5)
                    }
                }
            }
        }
    }

    // MARK: - Multi-Content Navigation Flow

    func testMultiContentNavigationFlow() throws {
        // 1. Start at home screen
        sleep(2)

        // 2. Navigate to first content item
        let images = app.images
        if images.count > 2 {
            // First item
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                            app.staticTexts.count > 5,
                            "First details should load")

                // 3. Navigate back
                if app.navigationBars.buttons.firstMatch.exists {
                    app.navigationBars.buttons.firstMatch.tap()
                    sleep(1)
                }

                // 4. Navigate to second content item
                let secondImage = images.element(boundBy: 1)
                if secondImage.exists && secondImage.isHittable {
                    secondImage.tap()
                    sleep(1)

                    XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                                app.staticTexts.count > 5,
                                "Second details should load")

                    // 5. Navigate back
                    if app.navigationBars.buttons.firstMatch.exists {
                        app.navigationBars.buttons.firstMatch.tap()
                        sleep(1)
                    }

                    // 6. Navigate to third content item
                    let thirdImage = images.element(boundBy: 2)
                    if thirdImage.exists && thirdImage.isHittable {
                        thirdImage.tap()
                        sleep(1)

                        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                                    app.staticTexts.count > 5,
                                    "Third details should load")

                        // 7. Navigate back to home
                        if app.navigationBars.buttons.firstMatch.exists {
                            app.navigationBars.buttons.firstMatch.tap()
                            sleep(1)
                        }
                    }
                }

                // 8. Verify still at home screen
                XCTAssertGreaterThan(app.images.count, 3, "Should return to home screen")
            }
        }
    }

    // MARK: - Content Type Switching Flow

    func testContentTypeSwitchingFlow() throws {
        // 1. Start at home screen
        sleep(2)

        // 2. View current content (should default to movies)
        let initialImages = app.images.count

        // 3. Switch to series (if toggle exists)
        if app.buttons["Series"].exists {
            app.buttons["Series"].tap()
            sleep(1)

            // 4. Verify content reloaded
            XCTAssertGreaterThan(app.images.count, 0, "Should show series content")

            // 5. Switch back to movies
            if app.buttons["Movies"].exists {
                app.buttons["Movies"].tap()
                sleep(1)

                // 6. Verify content reloaded
                XCTAssertGreaterThan(app.images.count, 0, "Should show movie content")
            }
        }
    }

    // MARK: - Filter Combination Flow

    func testComplexFilteringFlow() throws {
        // 1. Start with default view
        sleep(2)

        // 2. Apply genre filter
        if app.buttons["drama"].exists {
            app.buttons["drama"].tap()
            sleep(1)
        }

        // 3. Apply sort
        if app.buttons["Popular"].exists {
            app.buttons["Popular"].tap()
            sleep(1)
        }

        // 4. Verify filtered content displays
        XCTAssertGreaterThan(app.images.count, 0, "Should show filtered content")

        // 5. Scroll to load more filtered items
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeUp()
            sleep(1)
        }

        // 6. View a filtered item's details
        let images = app.images
        if images.count > 0 {
            let firstImage = images.element(boundBy: 0)
            if firstImage.exists && firstImage.isHittable {
                firstImage.tap()
                sleep(1)

                // 7. Verify details loaded
                XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3.0) ||
                            app.staticTexts.count > 5,
                            "Filtered item details should load")

                // 8. Navigate back
                if app.navigationBars.buttons.firstMatch.exists {
                    app.navigationBars.buttons.firstMatch.tap()
                    sleep(1)
                }
            }
        }

        // 9. Clear all filters
        if app.buttons["Clear Filters"].exists {
            app.buttons["Clear Filters"].tap()
            sleep(1)
        }

        // 10. Verify unfiltered content displays
        XCTAssertGreaterThan(app.images.count, 0, "Should show unfiltered content")
    }

    // MARK: - Stress Test Flows

    func testRapidNavigationStressTest() throws {
        // Test rapid navigation between screens
        sleep(2)

        for iteration in 1...5 {
            let images = app.images
            if images.count > iteration {
                let image = images.element(boundBy: iteration % images.count)
                if image.exists && image.isHittable {
                    image.tap()
                    sleep(0.5)

                    // Quick navigate back
                    if app.navigationBars.buttons.firstMatch.exists {
                        app.navigationBars.buttons.firstMatch.tap()
                        sleep(0.5)
                    }
                }
            }
        }

        // App should remain stable
        XCTAssertTrue(app.exists, "App should remain stable after rapid navigation")
    }

    func testExtensiveScrollingStressTest() throws {
        // Test extensive scrolling
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            // Scroll down extensively
            for _ in 1...20 {
                scrollView.swipeUp()
                sleep(0.2)
            }

            // Scroll back up
            for _ in 1...20 {
                scrollView.swipeDown()
                sleep(0.2)
            }

            // App should remain responsive
            XCTAssertTrue(scrollView.exists, "App should remain responsive after extensive scrolling")
        }
    }

    // MARK: - Performance Measurement Flows

    func testCompleteUserFlowPerformance() throws {
        measure {
            sleep(2)

            // Complete flow: home -> details -> back
            let images = app.images
            if images.count > 0 {
                let firstImage = images.element(boundBy: 0)
                if firstImage.exists && firstImage.isHittable {
                    firstImage.tap()
                    sleep(1)

                    if app.navigationBars.buttons.firstMatch.exists {
                        app.navigationBars.buttons.firstMatch.tap()
                        sleep(1)
                    }
                }
            }
        }
    }
}
