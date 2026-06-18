import XCTest

@MainActor
final class SecuritySettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPasscodeSetupAndAppSettingsGate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Face ID / Touch ID"].exists)

        tapSwitch("Passcode", in: app)
        XCTAssertTrue(app.staticTexts["Set Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("Update App Settings", in: app)

        tapBack(in: app)

        tapButton("DNS Resolver", in: app)
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Edit DNS settings"].waitForExistence(timeout: 2))

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["DNS Resolver"].waitForExistence(timeout: 5))
    }

    func testAppUnlockPromptsAndUnlocksAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapSwitch("Passcode", in: app)
        XCTAssertTrue(app.staticTexts["Set Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("App Unlock", in: app)

        app.terminate()
        app.launchEnvironment = [:]
        app.launch()

        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Unlock Lava"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.otherElements["securityLockOverlay"].exists)

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))
    }

    func testAppUnlockDoesNotPromptDuringForegroundTabSwitches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapSwitch("Passcode", in: app)
        XCTAssertTrue(app.staticTexts["Set Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("App Unlock", in: app)
        tapBack(in: app)

        tapRootTab("Guard", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 1))

        openGuardSection("How Lava filters", in: app)
        XCTAssertTrue(app.staticTexts["Filters"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 1))
        tapBack(in: app)

        openGuardSection("What Lava has caught", in: app)
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 1))
        tapBack(in: app)

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 1))
    }

    func testSecurityRequiresAuthenticationAfterLeavingAndReturning() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapSwitch("Passcode", in: app)
        XCTAssertTrue(app.staticTexts["Set Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))

        tapBack(in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Open Security settings"].waitForExistence(timeout: 2))

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapBack(in: app)
        tapRootTab("Guard", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Open Security settings"].waitForExistence(timeout: 2))
    }

    func testProtectionControlRequiresAuthenticationImmediatelyAfterEnablingSurface() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapSwitch("Passcode", in: app)
        XCTAssertTrue(app.staticTexts["Set Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("Turn on/off Lava", in: app)

        tapBack(in: app)
        tapRootTab("Guard", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))

        tapProtectionPrimaryAction(in: app)
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Change Lava protection"].waitForExistence(timeout: 2))

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 1))

        tapProtectionPrimaryAction(in: app)
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Change Lava protection"].waitForExistence(timeout: 2))
    }

    func testActivityViewingSelectsTabThenShowsAuthenticationGate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapSwitch("Passcode", in: app)
        XCTAssertTrue(app.staticTexts["Set Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("View Activities", in: app)

        tapBack(in: app)
        openGuardSection("What Lava has caught", in: app)
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unlock to view Activity"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Authentication Required"].exists)
        XCTAssertFalse(app.staticTexts["Unlock to view local activity"].exists)
        XCTAssertTrue(app.buttons["Authenticate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 1))

        app.buttons["Authenticate"].tap()
        XCTAssertTrue(app.staticTexts["Enter Passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["View Activity"].waitForExistence(timeout: 2))

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Local Logs"].waitForExistence(timeout: 5))
    }

    func testBiometricEnableRequestDoesNotCrashAfterPasscodeSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapSwitch("Passcode", in: app)
        XCTAssertTrue(app.staticTexts["Set Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm Passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        let biometricSwitch = app.switches["Face ID"].firstMatch.exists
            ? app.switches["Face ID"].firstMatch
            : app.switches["Touch ID"].firstMatch

        guard biometricSwitch.waitForExistence(timeout: 5) else {
            throw XCTSkip("Biometrics are not available on this test device")
        }

        biometricSwitch.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        XCTAssertTrue(biometricSwitch.waitForExistence(timeout: 3))
    }

    private func tapButton(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 2) {
            button.tap()
            return
        }

        let text = app.staticTexts[title].firstMatch
        if !text.waitForExistence(timeout: 2) {
            app.scrollViews.firstMatch.swipeUp()
        }

        XCTAssertTrue(text.waitForExistence(timeout: 5), "Missing control: \(title)")
        text.tap()
    }

    private func tapSwitch(_ title: String, in app: XCUIApplication) {
        let toggle = app.switches[title].firstMatch
        if !toggle.waitForExistence(timeout: 2) {
            app.scrollViews.firstMatch.swipeUp()
        }

        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Missing toggle: \(title)")
        if toggle.isHittable {
            toggle.tap()
            return
        }

        let label = app.staticTexts[title].firstMatch
        if label.waitForExistence(timeout: 1), label.isHittable {
            label.tap()
            return
        }

        let frame = toggle.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY))
            .tap()
    }

    /// Filters and Activity no longer live in the tab bar — they are reached from
    /// the Guard screen's explainer rows ("How Lava filters" / "What Lava has
    /// caught"). This opens Guard and taps the requested row.
    private func openGuardSection(_ rowTitle: String, in app: XCUIApplication) {
        tapRootTab("Guard", in: app)

        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", rowTitle)
        ).firstMatch
        if !row.waitForExistence(timeout: 2) {
            app.scrollViews.firstMatch.swipeUp()
        }

        XCTAssertTrue(row.waitForExistence(timeout: 5), "Missing Guard row: \(rowTitle)")
        row.tap()
    }

    private func tapRootTab(_ title: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons[title].firstMatch
        if button.waitForExistence(timeout: 2) {
            button.tap()
            return
        }

        let xOffset: CGFloat
        switch title {
        case "Guard":
            xOffset = 0.25
        case "Settings":
            xOffset = 0.75
        default:
            XCTFail("Unknown root tab: \(title)")
            return
        }

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 2) {
            let frame = tabBar.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.minX + frame.width * xOffset, dy: frame.midY))
                .tap()
            return
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: xOffset, dy: 0.94)).tap()
    }

    private func tapBack(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()
    }

    private func tapProtectionPrimaryAction(in app: XCUIApplication) {
        let turnOffButton = app.buttons["Turn Off"].firstMatch
        if turnOffButton.waitForExistence(timeout: 2) {
            turnOffButton.tap()
            return
        }

        let turnOnButton = app.buttons["Turn On"].firstMatch
        if turnOnButton.waitForExistence(timeout: 2) {
            turnOnButton.tap()
            return
        }

        let turnOffText = app.staticTexts["Turn Off"].firstMatch
        if turnOffText.waitForExistence(timeout: 2) {
            turnOffText.tap()
            return
        }

        let turnOnText = app.staticTexts["Turn On"].firstMatch
        XCTAssertTrue(turnOnText.waitForExistence(timeout: 5), "Missing protection action button")
        turnOnText.tap()
    }

    private func enterPasscode(_ passcode: String, in app: XCUIApplication) {
        app.typeText(passcode)
    }

}
