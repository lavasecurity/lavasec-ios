import XCTest

@MainActor
final class MediaCaptureDriverUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHoldRequestedDestinationForCapture() throws {
        guard let destination = ProcessInfo.processInfo.environment["LAVA_MEDIA_CAPTURE_DESTINATION"],
              let readyPath = ProcessInfo.processInfo.environment["LAVA_MEDIA_READY_PATH"]
        else {
            throw XCTSkip("Media capture driver requires destination and ready-path environment values.")
        }

        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        var launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        if let locale = environment["LAVA_MEDIA_LOCALE"], !locale.isEmpty {
            launchArguments += ["-AppleLanguages", String(format: "(%@)", locale)]
        }
        if let appleLocale = environment["LAVA_MEDIA_APPLE_LOCALE"], !appleLocale.isEmpty {
            launchArguments += ["-AppleLocale", appleLocale]
        }
        app.launchArguments = launchArguments
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))
        openFiltersOverview(in: app)

        switch destination {
        case "filters-overview":
            XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 5))
        case "now-filtering":
            tap("Now filtering", in: app)
            XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 5))
        case "your-filters":
            tap("Your filters", in: app)
            XCTAssertTrue(app.navigationBars["Your filters"].waitForExistence(timeout: 5))
        default:
            XCTFail("Unsupported media capture destination: \(destination)")
        }

        try Data("ready".utf8).write(to: URL(fileURLWithPath: readyPath))
        RunLoop.current.run(until: Date().addingTimeInterval(8))
    }

    private func openFiltersOverview(in app: XCUIApplication) {
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "How Lava filters")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Missing How Lava filters row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 5))
    }

    private func tap(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 2) {
            button.tap()
            return
        }

        let text = app.staticTexts[title].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Missing control: \(title)")
        text.tap()
    }
}
