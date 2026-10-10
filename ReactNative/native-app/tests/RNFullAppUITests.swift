import XCTest
import UIKit
import ImageIO
import Vision
import CoreML
import CoreImage

/// An explicit physical-device qualification lane. Unlike the simulator journeys,
/// this attaches to the already-running QA installation and never resets, relaunches,
/// or supplies defaults to it. Run with XCTest's UseDestinationArtifacts so the
/// signed preview and its extension are not replaced by the test build.
@MainActor
final class RNInstalledQAGuardUITests: XCTestCase {
    func testForegroundReentryKeepsConfirmedProtection() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the separately installed physical QA preview.")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LAVA_DEVICE_P0_QUALIFICATION"] == "1",
                          "Physical-device interaction requires explicit qualification opt-in.")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.lavasec.dev.qa")
        try XCTSkipUnless(app.state != .notRunning && app.state != .unknown,
                          "Open the existing QA app first; this test must not relaunch it.")
        app.activate()
        let status = app.otherElements["Protection status"].firstMatch
        try XCTSkipUnless(status.waitForExistence(timeout: 10),
                          "The existing app must be unlocked on Guard; do not bypass app security.")
        try XCTSkipUnless((status.value as? String)?.hasPrefix("Protected.") == true,
                          "Requires an already-confirmed session; does not manufacture VPN traffic.")
        var observations: [[String: String]] = []
        defer {
            let receipt = XCTAttachment(string: observations.map {
                "\($0["phase"] ?? ""): \($0["timestamp"] ?? "") \($0["value"] ?? "")"
            }.joined(separator: "\n"))
            receipt.name = "Installed QA foreground status observations"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
        for cycle in 1...3 {
            XCUIDevice.shared.press(.home)
            // This exercises app suspension/re-entry, not device lock or real
            // sleep. Those require separate provider sleep/wake evidence.
            Thread.sleep(forTimeInterval: 3)
            app.activate()
            let end = Date().addingTimeInterval(3)
            repeat {
                let value = status.value as? String ?? "missing"
                observations.append([
                    "phase": "resume-\(cycle)",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "value": value,
                ])
                XCTAssertTrue(value.hasPrefix("Protected."),
                              "A confirmed session lost its visible claim on app re-entry: \(value)")
                Thread.sleep(forTimeInterval: 0.15)
            } while Date() < end
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Installed QA Guard after foreground re-entry \(cycle)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        #endif
    }
}

@MainActor
final class RNMotionPreferenceUITests: XCTestCase {
    func testEnableReducedMotionWithoutCrossFade() throws { try configure(reduced: true, crossFade: false) }
    func testEnableCrossFade() throws { try configure(reduced: true, crossFade: true) }
    func testResetMotionPreferences() throws { try configure(reduced: false, crossFade: false) }

    private func configure(reduced: Bool, crossFade: Bool) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Motion preference qualification requires the task-private simulator.")
        #else
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        func open(_ title: String) {
            let row = settings.staticTexts[title].firstMatch
            for _ in 0..<12 where !row.isHittable { settings.swipeUp() }
            XCTAssertTrue(row.isHittable, settings.debugDescription)
            row.tap()
        }
        open("Accessibility")
        open("Motion")
        func toggle(_ title: String, to enabled: Bool) {
            let row = settings.switches[title].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), settings.debugDescription)
            if row.value as? String != (enabled ? "1" : "0") {
                let control = row.switches.firstMatch
                (control.exists ? control : row).tap()
            }
            let accepted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                row.value as? String == (enabled ? "1" : "0")
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 10), .completed)
        }
        // Cross-fade is exposed while Reduce Motion is on. Use the actual
        // Settings UI and verify UIKit; no guessed preference keys or mocks.
        toggle("Reduce Motion", to: true)
        toggle("Prefer Cross-Fade Transitions", to: crossFade)
        if !reduced { toggle("Reduce Motion", to: false) }
        let preference = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            UIAccessibility.isReduceMotionEnabled == reduced && UIAccessibility.prefersCrossFadeTransitions == crossFade
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [preference], timeout: 10), .completed)
        let receipt = XCTAttachment(string: "reduceMotion=\(UIAccessibility.isReduceMotionEnabled) crossFade=\(UIAccessibility.prefersCrossFadeTransitions)")
        receipt.name = "Verified UIKit motion preferences"
        receipt.lifetime = .keepAlways
        add(receipt)
        settings.terminate()
        #endif
    }
}

/// Separate opt-in lane: the host enrolls simulated Face ID and supplies exactly
/// one match per printed phase. Never auto-approve repeatedly: a second request
/// must leave this test waiting and fail. This exercises real LAContext callbacks.
@MainActor
final class RNSecurityBiometricUITests: XCTestCase {
    func testOneFaceIDPerEntryResumeAndColdLaunch() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the task-private simulator and biometric driver.")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LAVA_UI_TEST_BIOMETRIC_DRIVER"] == "1",
                          "Requires the host driver that approves each phase exactly once.")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["LAVA_UI_TEST_TRACE_PRESENTATION"] = "1"
        app.launchEnvironment["LAVA_UI_TEST_RESET_SECURITY"] = "1"
        app.launchEnvironment["LAVA_UI_TEST_PLAN"] = "free"
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["row.Security"].tap()
        let passcode = app.switches["Passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        passcode.tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        let biometric = app.switches["Face ID"]
        XCTAssertTrue(biometric.waitForExistence(timeout: 10))
        biometric.tap()
        NSLog("LAVA_FACEID_PHASE=enable")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            biometric.exists && biometric.value as? String == "1"
        }, object: nil)], timeout: 15), .completed)
        let unlock = app.switches["Open Lava"]
        func assertSettingsOrder() {
            let expected = ["Open Lava", "Turn protection on or off", "Pause protection", "Edit filters", "View Activity", "Change settings"]
            let labels = app.switches.allElementsBoundByIndex.map(\.label).filter { expected.contains($0) }
            XCTAssertEqual(labels, expected, "Snapshot updates must never reorder security controls")
        }
        assertSettingsOrder()
        unlock.tap()
        XCTAssertEqual(unlock.value as? String, "1")
        assertSettingsOrder()
        app.switches["Change settings"].tap()
        assertSettingsOrder()
        app.switches["View Activity"].tap()
        assertSettingsOrder()

        func assertRevealed(_ element: XCUIElement, phase: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                element.exists && element.isHittable && !app.otherElements["securityLockOverlay"].exists
                    && !app.otherElements["lavaPrivacyShield"].exists
            }, object: nil)], timeout: 15), .completed, app.debugDescription)
            XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1), "No fallback or second prompt")
            XCTAssertTrue(element.isHittable, "The revealed screen must remain usable")
            let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            capture.name = "One Face ID reveals \(phase)"
            capture.lifetime = .keepAlways
            add(capture)
        }
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        (back.exists ? back : app.navigationBars.buttons["Back"].firstMatch).tap()
        app.tabBars.buttons["Guard"].tap()
        app.buttons["guard.today"].tap()
        NSLog("LAVA_FACEID_PHASE=activity")
        assertRevealed(app.buttons["row.Top domains"], phase: "Activity entry")
        let activityBack = app.navigationBars.buttons["BackButton"].firstMatch
        (activityBack.exists ? activityBack : app.navigationBars.buttons["Back"].firstMatch).tap()
        app.tabBars.buttons["Settings"].tap()
        NSLog("LAVA_FACEID_PHASE=settings")
        assertRevealed(app.buttons["row.Security"], phase: "Settings entry")
        app.buttons["row.Security"].tap()
        NSLog("LAVA_FACEID_PHASE=entry")
        assertRevealed(passcode, phase: "Security entry")
        assertSettingsOrder()
        for cycle in 1...3 {
            XCUIDevice.shared.press(.home)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: nil)], timeout: 10), .completed)
            app.activate()
            NSLog("LAVA_FACEID_PHASE=resume-%d", cycle)
            assertRevealed(passcode, phase: "Security resume \(cycle)")
            assertSettingsOrder()
        }
        app.launchEnvironment["LAVA_UI_TEST_RESET_SECURITY"] = "0"
        app.terminate()
        app.launch()
        NSLog("LAVA_FACEID_PHASE=cold")
        assertRevealed(app.buttons["guard.today"], phase: "cold Guard launch")
        app.terminate()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        NSLog("LAVA_FACEID_PHASE=cold-zh")
        assertRevealed(app.buttons["guard.today"], phase: "Traditional Chinese cold Guard launch")
        #endif
    }
}

@MainActor
final class RNFullAppUITests: XCTestCase {
    private var restoreSystemTextSizeAfterCase = false

    override func tearDown() async throws {
        if restoreSystemTextSizeAfterCase {
            restoreSystemTextSizeAfterCase = false
            let app = XCUIApplication()
            app.activate()
            if !app.navigationBars["Customization"].exists {
                nativeTab(app, "Settings").tap()
                if !app.navigationBars["Customization"].exists {
                    let entry = app.buttons["row.Customization"]
                    XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
                    scrollFullyIntoView(app, entry)
                    entry.tap()
                }
            }
            XCTAssertTrue(app.navigationBars["Customization"].waitForExistence(timeout: 10), app.debugDescription)
            let system = app.switches["Match system"]
            XCTAssertTrue(system.waitForExistence(timeout: 10), app.debugDescription)
            scrollFullyIntoView(app, system)
            if system.value as? String == "0" { system.tap() }
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                system.value as? String == "1"
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed,
                           "Text-size qualification must restore the real system preference even after a failed assertion.")
        }
        try await super.tearDown()
    }

    func testNormalMotionPreferenceForFullTour() {
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled, "The default tour must qualify ordinary motion.")
        XCTAssertFalse(UIAccessibility.prefersCrossFadeTransitions, "Explicit cross-fade has a separate mandatory pass.")
    }
    func testImportSheetUsesNativeScrollHeaderAcrossMethodChanges() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Sheet navigation is checked on an isolated simulator.")
        #else
        defer { XCUIDevice.shared.orientation = .portrait }
        // iOS 18's compact landscape content can fit at the default text size.
        // Larger text makes the native scroll edge observable on that runtime.
        let category: String?
        if #available(iOS 26.0, *) { category = nil }
        else { category = "UICTContentSizeCategoryAccessibilityXXXL" }
        let app = launch(contentSizeCategory: category)
        let entry = app.buttons["guard.filter"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, entry)
        waitForSettledFrame(entry)
        entry.tap()
        let importButton = app.navigationBars["Filters"].buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        let header = fullSheetHeader(app, title: "Import a filter")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let scroll = app.scrollViews.containing(.button, identifier: "Enter a code").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        waitForSettledFrame(header)
        XCTAssertLessThan(scroll.frame.minY, header.frame.maxY - 10,
                          "The import scroll surface must extend under its native navigation bar.")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        let introduction = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Check who shared this filter")).firstMatch
        XCTAssertTrue(introduction.waitForExistence(timeout: 10))
        let initialY = introduction.frame.minY
        scroll.swipeUp()
        XCTAssertLessThan(introduction.frame.minY, initialY - 20)
        XCTAssertTrue(header.buttons["Close"].isHittable)
        capture(app, "Import sheet content beneath native translucent header")
        if #unavailable(iOS 26.0) {
            XCUIDevice.shared.orientation = .portrait
            assertWindowOrientation(app, landscape: false)
        }
        let enterCode = app.buttons["Enter a code"]
        waitForSettledFrame(enterCode)
        XCTAssertTrue(enterCode.isHittable)
        enterCode.tap()
        let codeHeader = fullSheetHeader(app, title: "Enter a code")
        XCTAssertTrue(codeHeader.waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        if #unavailable(iOS 26.0) {
            let codeScroll = app.scrollViews.containing(.staticText, identifier: "Setup code").firstMatch
            let continueButton = app.buttons["Continue"]
            XCTAssertTrue(codeScroll.exists)
            for _ in 0..<3 where input.frame.maxY > continueButton.frame.minY - 8 {
                codeScroll.swipeUp()
            }
        }
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let draft = "LF1-unsaved-header-check"
        input.typeText(draft)
        XCTAssertTrue((input.value as? String ?? "").contains(draft))
        XCTAssertTrue(codeHeader.buttons["Back"].isHittable)
        capture(app, "Translucent code entry header with keyboard and draft")
        codeHeader.buttons["Back"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let scan = app.buttons["Scan a QR code"]
        waitForSettledFrame(scan)
        XCTAssertTrue(scan.isHittable)
        scan.tap()
        let scannerHeader = fullSheetHeader(app, title: "Scan a QR code")
        XCTAssertTrue(scannerHeader.waitForExistence(timeout: 10))
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 2) {
            let deny = permission.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
            XCTAssertTrue(deny.exists)
            deny.tap()
        }
        // SwiftUI exposes its scroll surface separately from the navigation bar.
        let scannerBody = app.scrollViews.containing(NSPredicate(format: "label IN %@", [
            "Hold the shared QR code inside the frame.", "Camera access is off",
        ])).firstMatch
        XCTAssertTrue(scannerBody.waitForExistence(timeout: 10))
        XCTAssertLessThan(scannerBody.frame.minY, scannerHeader.frame.maxY - 10)
        capture(app, "QR import native translucent header")
        scannerHeader.buttons["Back"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.buttons["Close"].tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        #endif
    }

    func testPushedFilterHeadersUseNativeTitleAndScrollGeometry() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Navigation geometry is checked on an isolated simulator.")
        #else
        let app = launch(contentSizeCategory: "UICTContentSizeCategoryXXXL")
        let filterEntry = app.buttons["guard.filter"]
        XCTAssertTrue(filterEntry.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, filterEntry)
        filterEntry.tap()
        let filtersHeader = app.navigationBars["Filters"]
        XCTAssertTrue(filtersHeader.waitForExistence(timeout: 10))
        waitForSettledFrame(filtersHeader)
        let largeTitleHeight = filtersHeader.frame.height
        let libraryEntry = app.buttons["row.Switch or manage filters"]
        scrollFullyIntoView(app, libraryEntry)
        libraryEntry.tap()
        let libraryHeader = app.navigationBars["Your filters"]
        XCTAssertTrue(libraryHeader.waitForExistence(timeout: 10))
        waitForSettledFrame(libraryHeader)
        XCTAssertEqual(libraryHeader.frame.height, largeTitleHeight, accuracy: 2,
                       "Your filters must open with the same native large-title scaffold as Filters.")
        capture(app, "Your filters native large title")
        libraryHeader.buttons["Edit"].tap()
        let closeEditing = libraryHeader.buttons["Close edit mode"]
        XCTAssertTrue(closeEditing.waitForExistence(timeout: 10))
        waitForSettledFrame(libraryHeader)
        XCTAssertEqual(libraryHeader.frame.height, largeTitleHeight, accuracy: 2,
                       "Entering library edit mode must retain its title mode.")
        closeEditing.tap()
        nativeBack(app).tap()
        let activeFilter = app.buttons["row.Now filtering"]
        scrollFullyIntoView(app, activeFilter)
        activeFilter.tap()
        let detailHeader = app.navigationBars.firstMatch
        XCTAssertTrue(detailHeader.buttons["Edit"].waitForExistence(timeout: 10))
        waitForSettledFrame(detailHeader)
        let compactHeight = detailHeader.frame.height
        XCTAssertLessThan(compactHeight, largeTitleHeight - 10)
        let detailScroll = app.scrollViews.firstMatch
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 10))
        XCTAssertLessThan(detailScroll.frame.minY, detailHeader.frame.maxY - 10,
                          "Compact filter content must extend beneath the native bar.")
        detailHeader.buttons["Edit"].tap()
        XCTAssertTrue(detailHeader.buttons["Cancel editing"].waitForExistence(timeout: 10))
        waitForSettledFrame(detailHeader)
        XCTAssertEqual(detailHeader.frame.height, compactHeight, accuracy: 2)
        app.swipeUp()
        capture(app, "Filter edit content beneath native compact header")
        detailHeader.buttons["Cancel editing"].tap()
        nativeBack(app).tap()
        let automation = app.buttons["row.Auto-switch filters"]
        scrollFullyIntoView(app, automation)
        automation.tap()
        let automationHeader = app.navigationBars["Auto-switch filters"]
        XCTAssertTrue(automationHeader.waitForExistence(timeout: 10))
        waitForSettledFrame(automationHeader)
        XCTAssertEqual(automationHeader.frame.height, compactHeight, accuracy: 2)
        let automationPage = app.otherElements["auto-switch-page"]
        XCTAssertTrue(automationPage.waitForExistence(timeout: 10))
        let automationScrolls = app.scrollViews.containing(.other, identifier: "auto-switch-page")
        let automationScroll = automationScrolls.firstMatch
        XCTAssertTrue(automationScroll.waitForExistence(timeout: 10))
        XCTAssertEqual(automationScrolls.count, 1)
        waitForSettledFrame(automationScroll)
        XCTAssertLessThan(automationScroll.frame.minY, automationHeader.frame.maxY - 10,
                          "Shared automation scroll content must also extend beneath the parent bar.")
        // Fabric can flatten the intro's accessibility leaf out of its layout
        // container. Measure the unique rendered leaf on the actual page.
        let introduction = try renderedStaticText(app, "Switch filters on a schedule or with a Focus.")
        let introductionY = introduction.frame.minY
        automationScroll.swipeUp()
        XCTAssertLessThan(introduction.frame.minY, introductionY - 20,
                          "The hosted content must actually scroll behind the native header.")
        capture(app, "Auto-switch content beneath native compact header")
        #endif
    }

    func testNavigationScaffoldMatchesPageBackground() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Navigation geometry is checked on an isolated simulator.")
        #else
        let app = launch()
        for appearance in ["Light", "Dark"] {
            nativeTab(app, "Settings").tap()
            app.buttons["row.Customization"].tap()
            let choice = app.segmentedControls["Appearance"].buttons[appearance]
            XCTAssertTrue(choice.waitForExistence(timeout: 10))
            choice.tap()
            XCTAssertTrue(choice.wait(for: \.isSelected, toEqual: true, timeout: 10))
            nativeTab(app, "Guard").tap()
            app.buttons["guard.filter"].tap()
            let library = app.buttons["row.Switch or manage filters"]
            XCTAssertTrue(library.waitForExistence(timeout: 10))
            library.tap()
            try assertNavigationBackgroundMatchesPage(app, title: "Your filters")
            capture(app, "\(appearance) library shares the page background")
            nativeBack(app).tap()
            app.buttons["row.Now filtering"].tap()
            XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
            try assertNavigationBackgroundMatchesPage(app, title: app.navigationBars.firstMatch.identifier)
            capture(app, "\(appearance) filter detail shares the page background")
            nativeBack(app).tap()
            let automation = app.buttons["row.Auto-switch filters"]
            XCTAssertTrue(automation.waitForExistence(timeout: 10))
            automation.tap()
            try assertNavigationBackgroundMatchesPage(app, title: "Auto-switch filters")
            capture(app, "\(appearance) embedded automation shares the page background")
            nativeTab(app, "Guard").tap()
            nativeTab(app, "Settings").tap()
            nativeBack(app).tap()
        }
        #endif
    }

    func testNativeNavigationCollapsesAndRestoresOnScroll() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Navigation geometry is checked on an isolated simulator.")
        #else
        let app = launch()
        nativeTab(app, "Settings").tap()
        let header = app.navigationBars["Settings"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        waitForSettledFrame(header)
        let expandedHeader = header.frame.height
        let selectedTab = app.tabBars.buttons["Settings"]
        waitForSettledFrame(selectedTab)
        let expandedTab = selectedTab.frame
        app.swipeUp()
        waitForSettledFrame(header)
        XCTAssertLessThan(header.frame.height, expandedHeader - 10,
                          "UIKit must collapse the large title with the page scroll.")
        capture(app, "Native navigation after upward content scroll")
        print("LAVA_NAVIGATION_TABS \(app.tabBars.firstMatch.debugDescription)")
        if #available(iOS 27.0, *) {
            // UITabBar retains its full-width safe-area frame when its visible
            // glass capsule minimizes. Measure the selected control inside it.
            let minimized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                selectedTab.exists && selectedTab.frame.width < expandedTab.width - 10
            }, object: selectedTab)
            XCTAssertEqual(XCTWaiter.wait(for: [minimized], timeout: 5), .completed,
                           "The native tab must minimize: expanded \(expandedTab), current \(selectedTab.frame).")
        }
        app.swipeDown()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(selectedTab.frame.width - expandedTab.width) < 2
                && abs(selectedTab.frame.height - expandedTab.height) < 2
        }, object: selectedTab)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "Reverse scrolling must restore the native tab bar.")
        capture(app, "Native navigation restored on reverse scroll")
        #endif
    }

    func testEmbeddedNativePageMinimizesTabBarOnScroll() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Navigation geometry is checked on an isolated simulator.")
        #else
        let app = launch(largeText: true)
        let filter = app.buttons["guard.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, filter)
        filter.tap()
        let automation = app.buttons["row.Auto-switch filters"]
        XCTAssertTrue(automation.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, automation)
        waitForSettledFrame(automation)
        automation.tap()
        let header = app.navigationBars["Auto-switch filters"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        waitForSettledFrame(header)
        // Return to the content edge before measuring the expanded tab control.
        app.swipeDown()
        let selectedTab = app.tabBars.buttons["Guard"]
        waitForSettledFrame(selectedTab)
        let expandedTab = selectedTab.frame
        app.swipeUp()
        capture(app, "Embedded auto-switch native page scrolled with large text")
        if #available(iOS 27.0, *) {
            let minimized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                selectedTab.exists && selectedTab.frame.width < expandedTab.width - 10
            }, object: selectedTab)
            XCTAssertEqual(XCTWaiter.wait(for: [minimized], timeout: 5), .completed,
                           "The native scroll view must minimize the enclosing React tab bar.")
        }
        #endif
    }

    private func assertNavigationBackgroundMatchesPage(_ app: XCUIApplication, title: String) throws {
        let header = app.navigationBars[title]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        waitForSettledFrame(header)
        let screenshot = app.screenshot().image
        let image = try XCTUnwrap(screenshot.cgImage)
        func sample(at point: CGPoint) throws -> [Int] {
            let crop = try XCTUnwrap(image.cropping(to: CGRect(
                x: point.x * screenshot.scale, y: point.y * screenshot.scale,
                width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba.prefix(3).map(Int.init)
        }
        // The left gutter avoids the native glass Back control and page cards.
        let x = app.frame.minX + 4
        let bar = try sample(at: CGPoint(x: x, y: header.frame.midY))
        let page = try sample(at: CGPoint(x: x, y: header.frame.maxY + 10))
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(bar[channel] - page[channel]), 8,
                                    "\(title) must not paint a separate stripe: bar \(bar), page \(page).")
        }
    }

    func testCompactSharedRowsPreserveEditTargetsAndGrowForLargeText() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Row geometry is checked on an isolated simulator.")
        #else
        for largeText in [false, true] {
            let app = launch(largeText: largeText)
            let filter = app.buttons["guard.filter"]
            XCTAssertTrue(filter.waitForExistence(timeout: 10))
            scrollFullyIntoView(app, filter)
            XCTAssertTrue(filter.wait(for: \.isHittable, toEqual: true, timeout: 15))
            filter.tap()
            let manage = app.buttons["row.Switch or manage filters"]
            XCTAssertTrue(manage.waitForExistence(timeout: 10))
            scrollFullyIntoView(app, manage)
            waitForSettledFrame(manage)
            if largeText {
                XCTAssertGreaterThan(manage.frame.height, 58, "Large text must grow beyond the row floor.")
            } else {
                XCTAssertEqual(manage.frame.height, 58, accuracy: 1)
                let autoSwitch = app.buttons["row.Auto-switch filters"]
                scrollFullyIntoView(app, autoSwitch)
                XCTAssertEqual(autoSwitch.frame.height, 58, accuracy: 1)
            }
            capture(app, largeText ? "Compact rows at accessibility text size" : "58pt navigation rows")
            scrollFullyIntoView(app, manage)
            manage.tap()
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "filter.library."))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
            let first = rows.firstMatch
            scrollFullyIntoView(app, first)
            waitForSettledFrame(first)
            let readingHeight = first.frame.height
            XCTAssertGreaterThan(readingHeight, 58, "Title and metadata retain their content padding.")
            app.navigationBars.buttons["Edit"].tap()
            scrollFullyIntoView(app, first)
            waitForSettledFrame(first)
            XCTAssertEqual(first.frame.height, readingHeight, accuracy: 1,
                           "Editing must not add padding around accessory touch targets.")
            if !largeText {
                let delete = app.buttons.matching(identifier: "Delete").firstMatch
                XCTAssertTrue(delete.waitForExistence(timeout: 10))
                XCTAssertEqual(delete.frame.height, 44, accuracy: 1)
                XCTAssertEqual(delete.frame.width, 44, accuracy: 1)
            }
            capture(app, largeText ? "Expanded rows retain edit alignment" : "Metadata rows retain 44pt edit targets")
            app.navigationBars.buttons["Close edit mode"].tap()
            app.terminate()
        }
        #endif
    }

    func testMockOnboardingRehearsesFreshSetupWithoutChangingGuard() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Use an isolated simulator for the mock onboarding journey.")
        #else
        print("LAVA_ONBOARDING_QA reduceMotion=\(UIAccessibility.isReduceMotionEnabled)")
        let app = launch()
        XCTAssertTrue(app.otherElements["guard.mascot"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["guard.filter"].waitForExistence(timeout: 10))
        let canonicalMascot = app.otherElements["guard.mascot"].frame
        let filterBefore = app.buttons["guard.filter"].label
        let levelBefore = try XCTUnwrap(["Core", "Balanced", "Extra"].first { filterBefore.contains($0) })
        nativeTab(app, "Settings").tap()
        let qa = app.buttons["row.Device QA"]
        scrollFullyIntoView(app, qa)
        qa.tap()
        let mock = app.buttons["qa.mock-onboarding"]
        XCTAssertTrue(mock.waitForExistence(timeout: 15), app.debugDescription)
        mock.tap()
        let primary = app.buttons["onboarding.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        // The full-window modal's first native safe-area measurement can arrive
        // after its accessibility element appears. Compare settled page frames.
        waitForSettledFrame(primary)
        let welcomeButtonFrame = primary.frame
        capture(app, "Onboarding welcome")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        XCTAssertTrue(app.staticTexts["Lava stands guard here"].waitForExistence(timeout: 10))
        waitForSettledFrame(primary)
        capture(app, "Benefits with Settings outline glyphs")
        let featureTitleTop = try renderedStaticText(app, "Lava stands guard here").frame.minY
        XCTAssertEqual(primary.frame, welcomeButtonFrame, "The inward welcome border must preserve the filled button's geometry.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        let vpn = app.descendants(matching: .any).matching(identifier: "onboarding.install-vpn").firstMatch
        XCTAssertTrue(vpn.waitForExistence(timeout: 10))
        XCTAssertEqual(try renderedStaticText(app, "First, let’s get Lava ready to help.").frame.minY,
                       featureTitleTop, accuracy: 1, "Page 2 and page 3 headings share the same top position.")
        XCTAssertFalse(primary.isEnabled)
        XCTAssertEqual(primary.label, "Install VPN first")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Step [0-9]+" )).count, 0)
        capture(app, "Quiet permission cards with outline glyphs")
        vpn.tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "VPN installed"), object: vpn
        )], timeout: 10), .completed)
        waitForSettledFrame(app.buttons["onboarding.notifications"])
        XCTAssertTrue(app.buttons["onboarding.notifications"].isEnabled)
        app.buttons["onboarding.notifications"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Notifications enabled"),
            object: app.descendants(matching: .any).matching(identifier: "onboarding.notifications").firstMatch
        )], timeout: 10), .completed)
        XCTAssertEqual(app.alerts.count, 0, "Mock permissions must not open system dialogs.")
        capture(app, "Mock setup success uses filled cards")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        let extra = app.buttons["onboarding.filter.comprehensive"]
        XCTAssertTrue(extra.waitForExistence(timeout: 10))
        capture(app, "Separate filter choice cards")
        extra.tap()
        XCTAssertEqual(extra.value as? String, "On")
        XCTAssertEqual(app.buttons["onboarding.filter.balanced"].value as? String, "Off")
        capture(app, "Selected filter uses filled card and white trailing glyph")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        XCTAssertTrue(app.staticTexts["Lastly, let’s keep your connection running smoothly."].waitForExistence(timeout: 10))
        let fallback = app.buttons["onboarding.dns-fallback"]
        let profile = app.buttons["onboarding.dns-profile"]
        XCTAssertEqual(fallback.value as? String, "On")
        XCTAssertEqual(profile.value as? String, "On")
        capture(app, "Both connection choices start selected")
        profile.tap()
        XCTAssertEqual(profile.value as? String, "Off")
        XCTAssertEqual(fallback.value as? String, "On")
        profile.tap()
        fallback.tap()
        XCTAssertEqual(fallback.value as? String, "Off")
        XCTAssertEqual(profile.value as? String, "On")
        capture(app, "Connection cards share filled selection and trailing glyphs")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        let travelStart = app.otherElements["onboarding.mascot"].frame
        primary.tap()
        let intermediateTravel = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let moving = app.otherElements["onboarding.mascot"].frame
            return abs(moving.midX - travelStart.midX) > 3 && abs(moving.midX - canonicalMascot.midX) > 3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [intermediateTravel], timeout: 3), .completed,
                       "First arrival must visibly travel, not just match its destination.")
        XCTAssertTrue(app.otherElements["onboarding.ready"].waitForExistence(timeout: 10))
        let finaleDots = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "Step [0-9]+ of 6"))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in finaleDots.count == 0 }, object: nil
        )], timeout: 5), .completed, "After the outgoing transition, hidden finale dots must leave accessibility.")
        XCTAssertEqual(app.otherElements["onboarding.ready"].value as? String, "Your next step to a safer internet.")
        // Decorative art has no hit target; its measured drawing slot must settle.
        waitForSettledFrame(app.otherElements["onboarding.mascot"], requiresHittable: false)
        let finalMascot = app.otherElements["onboarding.mascot"].frame
        print("LAVA_HANDOFF_FRAMES mock=\(finalMascot) canonical=\(canonicalMascot)")
        XCTAssertEqual(finalMascot.minX, canonicalMascot.minX, accuracy: 1)
        XCTAssertEqual(finalMascot.minY, canonicalMascot.minY, accuracy: 1)
        XCTAssertEqual(finalMascot.width, canonicalMascot.width, accuracy: 1)
        XCTAssertEqual(finalMascot.height, canonicalMascot.height, accuracy: 1)
        capture(app, "Final smiling pose and safer internet copy")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        XCTAssertTrue(primary.waitForNonExistence(timeout: 10), "Wait for the mock’s final hold and dismissal before reentry.")
        XCTAssertTrue(mock.waitForExistence(timeout: 10), "Completing the mock returns to QA.")
        mock.tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        XCTAssertTrue(vpn.waitForExistence(timeout: 10))
        XCTAssertTrue(vpn.label.contains("Install local VPN"))
        XCTAssertFalse(primary.isEnabled, "Every rehearsal starts uninstalled.")
        waitForSettledFrame(app.buttons["onboarding.notifications"])
        XCTAssertTrue(app.buttons["onboarding.notifications"].isEnabled)
        app.buttons["onboarding.notifications"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Notifications enabled"), object: app.descendants(matching: .any).matching(identifier: "onboarding.notifications").firstMatch)], timeout: 10), .completed)
        XCTAssertTrue(vpn.label.contains("Install local VPN"), "Notifications alone must leave VPN setup incomplete.")
        XCTAssertFalse(primary.isEnabled)
        app.buttons["Close"].tap()
        XCTAssertTrue(mock.waitForExistence(timeout: 10))
        nativeTab(app, "Guard").tap()
        // Rule counts can change as the real app's existing background sync finishes.
        XCTAssertTrue(app.buttons["guard.filter"].label.contains(levelBefore), "Mock choices must not change the selected protection level.")
        #endif
    }

    func testNativeSwitchRemainsAvailableAfterMockOnboardingCloses() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Use an isolated simulator for the mock onboarding journey.")
        #else
        let app = launch()
        nativeTab(app, "Settings").tap()
        let qa = app.buttons["row.Device QA"]
        scrollFullyIntoView(app, qa)
        qa.tap()
        let mock = app.buttons["qa.mock-onboarding"]
        for _ in 0..<2 {
            XCTAssertTrue(mock.waitForExistence(timeout: 10))
            mock.tap()
            XCTAssertTrue(app.buttons["onboarding.primary"].waitForExistence(timeout: 10))
            app.buttons["Close"].tap()
            XCTAssertTrue(app.buttons["onboarding.primary"].waitForNonExistence(timeout: 10))
        }
        nativeTab(app, "Guard").tap()
        app.buttons["guard.explore"].tap()
        // First mount of a native switch must work after the preview host is
        // destroyed; visiting Explore before the demo would hide this regression.
        let narration = app.switches["Narration"]
        XCTAssertTrue(narration.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(narration.value as? String, "0")
        narration.tap()
        XCTAssertEqual(narration.value as? String, "1")
        narration.tap()
        XCTAssertEqual(narration.value as? String, "0")
        capture(app, "Explore native narration switch after repeated mock dismissal")
        nativeTab(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Device QA"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Back"].tap()
        let feedback = app.buttons["row.Feedback"]
        scrollFullyIntoView(app, feedback)
        feedback.tap()
        XCTAssertTrue(app.buttons["1. Topic"].waitForExistence(timeout: 10), "A dismissed preview must leave the main foreground factory usable.")
        capture(app, "Shared feedback sheet remains usable after repeated mock dismissal")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["1. Topic"].waitForNonExistence(timeout: 10))
        #endif
    }

    func testDNSPatchSharesAutoSwitchSetupScaffold() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Visual setup comparison uses an isolated simulator; no DNS settings are saved.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["LAVA_UI_TEST_DNS_PATCH"] = "1"
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        nativeTab(app, "Guard").tap()
        app.buttons["guard.explore"].tap()
        let dns = app.buttons["connection.dns"]
        XCTAssertTrue(dns.waitForExistence(timeout: 10))
        waitForSettledFrame(dns)
        dns.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in dns.isSelected }, object: dns
        )], timeout: 10), .completed, "The settled DNS step must be selected before revealing its setup links.")
        let patch = app.buttons["explore.dns-patch"]
        XCTAssertTrue(patch.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, patch, throughGutter: true)
        patch.tap()
        XCTAssertTrue(app.navigationBars["DNS patch for iOS 27"].waitForExistence(timeout: 10))
        capture(app, "DNS patch shared scaffold introduction")
        let settings = app.buttons["Open the Settings app"]
        scrollFullyIntoView(app, settings)
        XCTAssertTrue(settings.exists)
        capture(app, "DNS patch instructions and actions share panels")
        let vpn = app.buttons["Open VPN chaining"]
        scrollFullyIntoView(app, vpn)
        XCTAssertTrue(vpn.exists)
        capture(app, "DNS patch shared scaffold full tunnel action")
        nativeBack(app).tap()
        nativeTab(app, "Guard").tap()
        app.buttons["guard.filter"].tap()
        let automation = app.buttons["row.Auto-switch filters"]
        scrollFullyIntoView(app, automation)
        automation.tap()
        XCTAssertTrue(app.navigationBars["Auto-switch filters"].waitForExistence(timeout: 10))
        capture(app, "Auto-switch shared scaffold reference")
        // Read-only rendering: do not select setup, Settings, VPN or removal actions.
        #endif
    }

    func testRound40NativeImportMenuUsesContiguousRows() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Read-only local simulator menu qualification; never open camera or photos.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        let filter = app.buttons["guard.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        filter.tap()
        let importButton = app.navigationBars["Filters"].buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), app.debugDescription)
        importButton.tap()
        let scan = app.buttons["Scan a QR code"], photo = app.buttons["Import from photo"], code = app.buttons["Enter a code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(photo.exists)
        XCTAssertTrue(code.exists)
        waitForSettledFrame(photo)
        XCTAssertEqual(scan.frame.height, photo.frame.height, accuracy: 1)
        XCTAssertEqual(photo.frame.height, code.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(abs(photo.frame.minY - scan.frame.maxY), 2)
        XCTAssertLessThanOrEqual(abs(code.frame.minY - photo.frame.maxY), 2)
        capture(app, "R40 native import grouped rows and three chevrons")
        // Do not select an import method or request camera/photo permissions.
        app.navigationBars["Import a filter"].buttons["Close"].tap()
        #endif
    }

    func testRound40GuardPickerScrollsSpotlightChoicesAndIconRowTogether() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Read-only local simulator layout qualification; never operate the phone.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Preserve the existing installation and its selected Guard.
        app.launch()
        XCTAssertTrue(nativeTab(app, "Settings").waitForExistence(timeout: 30))
        nativeTab(app, "Settings").tap()
        let customization = app.buttons["row.Customization"]
        scrollFullyIntoView(app, customization)
        customization.tap()
        let choose = app.buttons["Choose Lava Guard"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        waitForSettledFrame(choose)
        choose.tap()
        let header = fullSheetHeader(app, title: "Lava Guard")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "guardian.option.")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        let title = selected.label
        let spotlight = app.staticTexts[title].firstMatch
        XCTAssertTrue(spotlight.waitForExistence(timeout: 10), app.debugDescription)
        let match = app.switches.matching(NSPredicate(format: "label ==[c] %@", "Match app icon to Lava Guard")).firstMatch
        let lists = app.scrollViews.containing(.any, identifier: "guardian.options")
        let list = lists.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(lists.count, 1)
        XCTAssertTrue(list.staticTexts[title].exists, "The active spotlight belongs to the choices' shared scroll owner.")
        XCTAssertTrue(list.switches.matching(NSPredicate(format: "label ==[c] %@", "Match app icon to Lava Guard")).firstMatch.exists)
        XCTAssertTrue(match.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(list.frame.height, 88)
        let first = app.buttons["guardian.option.original"]
        XCTAssertTrue(first.exists)
        waitForSettledFrame(first, requiresHittable: false)
        let headerFrame = header.frame, spotlightY = spotlight.frame.minY
        let firstY = first.frame.minY, matchY = match.frame.minY
        let beforeMatch = match.value as? String
        capture(app, "Guard picker active spotlight and choices share one page")
        scrollFullyIntoView(app, match, in: list, throughGutter: true)
        waitForSettledFrame(match)
        let movement = first.frame.minY - firstY
        XCTAssertLessThan(movement, -10, "The choices must move when revealing the icon row.")
        XCTAssertEqual(spotlight.frame.minY - spotlightY, movement, accuracy: 1.5)
        XCTAssertEqual(match.frame.minY - matchY, movement, accuracy: 1.5)
        XCTAssertEqual(header.frame.minY, headerFrame.minY, accuracy: 1)
        XCTAssertEqual(header.frame.height, headerFrame.height, accuracy: 1)
        XCTAssertTrue(match.isHittable)
        XCTAssertEqual(match.value as? String, beforeMatch, "Scrolling cannot toggle icon matching.")
        XCTAssertTrue(selected.isSelected, "Scrolling cannot change the selected Guard.")
        capture(app, "Guard picker scrolls spotlight choices and icon row beneath its native header")
        header.buttons["Close"].tap()
        #endif
    }

    func testRound9PreviewPagesAndNativeTabs() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local preview qualification only; do not operate the review phone.")
        #else
        let app = launch()
        capture(app, "Round 9 Guard resting material")
        for _ in 0..<10 {
            nativeTab(app, "Settings").tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            nativeTab(app, "Guard").tap()
        }
        nativeTab(app, "Settings").tap()
        let account = app.buttons["row.Account & Backup"]
        scrollFullyIntoView(app, account)
        account.tap()
        XCTAssertTrue(app.navigationBars["Account & backup"].waitForExistence(timeout: 5))
        let backup = app.switches["Enable backup"]
        if app.staticTexts["Not signed in"].exists {
            XCTAssertTrue(backup.waitForExistence(timeout: 5))
            XCTAssertEqual(backup.value as? String, "0")
            XCTAssertFalse(backup.isEnabled)
        }
        capture(app, "Round 9 signed-out backup")
        app.navigationBars.buttons.firstMatch.tap()
        let plus = app.buttons["row.Get Lava Plus today"].exists ? app.buttons["row.Get Lava Plus today"] : app.buttons["row.Thank you for using Lava Plus"]
        scrollFullyIntoView(app, plus)
        plus.tap()
        XCTAssertTrue(app.staticTexts["More ways to make Lava your own"].waitForExistence(timeout: 5))
        let carousel = app.descendants(matching: .any).matching(identifier: "carousel.scroll").firstMatch
        capture(app, "Round 9 Plus initial render")
        XCTAssertTrue(carousel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThan(carousel.frame.height, 150)
        let sharedCardHeight = carousel.frame.height
        capture(app, "Round 9 Plus first page")
        carousel.swipeLeft()
        XCTAssertTrue(app.staticTexts["Choose how you connect"].waitForExistence(timeout: 5))
        XCTAssertEqual(carousel.frame.height, sharedCardHeight, accuracy: 1)
        capture(app, "Round 9 Plus connection page")
        carousel.swipeLeft()
        XCTAssertTrue(app.staticTexts["Find your Lava"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Next Lava Guard"].exists)
        XCTAssertEqual(carousel.frame.height, sharedCardHeight, accuracy: 1)
        capture(app, "Plus static Guard illustration")
        let included = app.buttons["row.Everything included"]
        scrollFullyIntoView(app, included)
        included.tap()
        XCTAssertTrue(app.staticTexts["Saved filters"].waitForExistence(timeout: 5))
        capture(app, "Round 9 Plus expanded benefits")
        nativeTab(app, "Guard").tap()
        app.buttons["guard.explore"].tap()
        let play = app.buttons["explore.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        capture(app, "Round 9 separate Explore demo")
        // Pause explicit autoplay before manually inspecting deterministic frames.
        app.buttons["explore.transport.play"].tap()
        app.buttons["explore.next"].tap()
        let lookupCaption = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "That question goes to DNS")).firstMatch
        XCTAssertTrue(lookupCaption.waitForExistence(timeout: 5))
        capture(app, "Round 9 Explore next step")
        app.buttons["connection.filter"].tap()
        XCTAssertTrue(app.buttons["explore.configure"].waitForExistence(timeout: 5))
        capture(app, "Round 9 Explore inspection")
        #endif
    }
    func testRound9GlyphAndModeRendering() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local simulator rendering check only.")
        #else
        let app = launch()
        app.buttons["guard.explore"].tap()
        let play = app.buttons["explore.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        app.buttons["explore.transport.play"].tap()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "Round 9 visible Device aperture")
        app.buttons["explore.next"].tap()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "Round 9 visible DNS aperture")
        app.navigationBars.buttons.firstMatch.tap()
        let mascot = app.descendants(matching: .any).matching(identifier: "guard.mascot").firstMatch
        openSudoku(mascot, in: app)
        let rail = sudokuRail(app)
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        let notes = app.buttons["sudoku-notes-toggle"]
        let assist = app.buttons["sudoku-correctness-toggle"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        let notesFrame = notes.frame, assistFrame = assist.frame
        XCTAssertEqual(notesFrame.width, 44, accuracy: 0.5)
        XCTAssertEqual(notesFrame.height, 44, accuracy: 0.5)
        XCTAssertEqual(assistFrame.width, 44, accuracy: 0.5)
        XCTAssertEqual(assistFrame.height, 44, accuracy: 0.5)
        for index in 0..<4 {
            if index == 1 || index == 3 { notes.tap() }
            if index == 2 { assist.tap() }
            XCTAssertEqual(notes.frame.width, notesFrame.width, accuracy: 0.5)
            XCTAssertEqual(notes.frame.height, notesFrame.height, accuracy: 0.5)
            XCTAssertEqual(notes.frame.midX, notesFrame.midX, accuracy: 0.5)
            XCTAssertEqual(assist.frame.width, assistFrame.width, accuracy: 0.5)
            XCTAssertEqual(assist.frame.midX, assistFrame.midX, accuracy: 0.5)
            capture(app, "Round 9 fixed mode canvas combination \(index)")
        }
        // All four combinations finish with ordinary entry + Eye on. On this private
        // simulator, find a valid user-cell value through normal puzzle controls.
        let empty = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "sudoku-cell-", ": empty")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        empty.tap()
        let outcome = app.images["sudoku-correctness-outcome"]
        for digit in 1...9 {
            app.buttons["sudoku-digit-\(digit)"].tap()
            if outcome.label == "Correctly placed" { break }
        }
        XCTAssertTrue(outcome.exists)
        XCTAssertEqual(outcome.label, "Correctly placed")
        XCTAssertGreaterThanOrEqual(outcome.frame.height, 44)
        XCTAssertGreaterThanOrEqual(outcome.frame.width, 44)
        capture(app, "Round 9 actual Eye green correctness checkmark")
        #endif
    }
    func testSudokuSharedRailTransposesOnRotation() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local simulator rendering check only.")
        #else
        let app = launch()
        let mascot = app.descendants(matching: .any).matching(identifier: "guard.mascot").firstMatch
        openSudoku(mascot, in: app)
        XCTAssertTrue(sudokuNotesControl(app).waitForExistence(timeout: 5))
        let rail = sudokuRail(app)
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertEqual(rail.frame.height, 44, accuracy: 0.5)
        let close = app.buttons["sudoku-close"]
        let notes = app.buttons["sudoku-notes-toggle"]
        let assist = app.buttons["sudoku-correctness-toggle"]
        let reset = app.buttons["sudoku-reset"]
        let newPuzzle = app.buttons["sudoku-refresh"]
        XCTAssertLessThan(close.frame.midX, notes.frame.midX)
        XCTAssertLessThan(notes.frame.midX, assist.frame.midX)
        XCTAssertLessThan(assist.frame.midX, reset.frame.midX)
        XCTAssertLessThan(reset.frame.midX, newPuzzle.frame.midX)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        let railRotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(rail.frame.width - 44) <= 0.5 && rail.frame.height > rail.frame.width
        }, object: rail)
        XCTAssertEqual(XCTWaiter.wait(for: [railRotated], timeout: 10), .completed)
        XCTAssertEqual(rail.frame.width, 44, accuracy: 0.5)
        XCTAssertLessThan(close.frame.midY, notes.frame.midY)
        XCTAssertLessThan(notes.frame.midY, assist.frame.midY)
        XCTAssertLessThan(assist.frame.midY, reset.frame.midY)
        XCTAssertLessThan(reset.frame.midY, newPuzzle.frame.midY)
        var previousDigit: XCUIElement?
        for value in 1...9 {
            let digit = app.buttons["sudoku-digit-\(value)"]
            XCTAssertTrue(digit.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(digit.frame.height, 20, "Landscape digit \(value) must remain visible.")
            if value == 1 { XCTAssertGreaterThan(digit.frame.minY, 24, "The first digit must clear the system gesture edge.") }
            XCTAssertGreaterThan(digit.frame.midX, app.frame.midX)
            XCTAssertLessThanOrEqual(digit.frame.maxX, app.frame.maxX)
            if let previousDigit { XCTAssertLessThan(previousDigit.frame.midY, digit.frame.midY) }
            previousDigit = digit
        }
        capture(app, "Sudoku shared rail landscape")
        #endif
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    func testContextMenuConsumesButtonContactBeforeRelease() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        let gallery = app.buttons["row.Design system"]
        for _ in 0..<6 where !gallery.isHittable { app.swipeUp() }
        XCTAssertTrue(gallery.isHittable, app.debugDescription)
        gallery.tap()
        let button = app.buttons["gallery.context-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        func assertCounts(taps: Int, selections: Int) {
            XCTAssertTrue(app.staticTexts["Context button taps: \(taps); menu selections: \(selections)"].waitForExistence(timeout: 5), app.debugDescription)
        }
        button.tap()
        assertCounts(taps: 1, selections: 0)
        for duration in [0.7, 1.5, 0.7] {
            button.press(forDuration: duration)
            let pause = app.buttons["Pause for 5 minutes"]
            XCTAssertTrue(pause.waitForExistence(timeout: 5), app.debugDescription)
            // Dismiss without selecting. The same contact must not fall through
            // into the React button when UIKit releases its native menu.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).tap()
            XCTAssertTrue(pause.waitForNonExistence(timeout: 5))
            assertCounts(taps: 1, selections: 0)
        }
        button.press(forDuration: 0.7)
        let pause = app.buttons["Pause for 5 minutes"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        assertCounts(taps: 1, selections: 1)
        button.tap()
        assertCounts(taps: 2, selections: 1)
        capture(app, "Context menu consumes holds and restores the next intentional tap")
    }

    private func launch(delayedQueries: Bool = false, guardPicker: Bool = false, largeText: Bool = false, rageShake: Bool = false, paidPlan: Bool = false, retainShareCardEvidence: Bool = false, contentSizeCategory: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Skip onboarding only for this test process; retain real app controllers,
        // configuration storage, security, and extensions throughout the journey.
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if retainShareCardEvidence { app.launchArguments.append("-LavaUITestRetainShareCardPNG") }
        if paidPlan { app.launchArguments += ["-LavaQAForcePaidPlan", "YES"] }
        if let category = contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        } else if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LAVA_UI_TEST_RESET_SECURITY"] = "1"
        app.launchEnvironment["LAVA_UI_TEST_PLAN"] = paidPlan ? "paid" : "free"
        if delayedQueries { app.launchEnvironment["LAVA_UI_TEST_DELAY_QUERIES"] = "1" }
        if guardPicker { app.launchEnvironment["LAVA_UI_TEST_GUARD_PICKER"] = "1" }
        if rageShake { app.launchArguments.append("-lava-trigger-rage-shake") }
        app.launch()
        if rageShake { return app }
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(nativeTab(app, "Guard").waitForExistence(timeout: 15), app.debugDescription)
        // Rotation journeys can leave the simulator or a restored app scene in
        // landscape. Establish each journey's portrait baseline on the actual
        // foreground window before checking geometry or interacting with rows.
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.height > app.frame.width && app.frame.width > 0
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed,
                       "Each journey must start with a settled portrait window.")
        return app
    }
    private func nativeBack(_ app: XCUIApplication) -> XCUIElement {
        let systemBack = app.navigationBars.buttons["BackButton"].firstMatch
        return systemBack.exists ? systemBack : app.navigationBars.buttons["Back"].firstMatch
    }
    /// The game owns one rail in either orientation, independent of UIKit's
    /// navigation bar accessibility hierarchy.
    private func sudokuRail(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sudoku-rail").firstMatch
    }
    private func sudokuNotesControl(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Notes mode off", "Notes mode on"])).element
    }
    private func nativeTab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        precondition(name == "Guard" || name == "Settings")
        // iOS minimizes the floating tab bar after scrolling. Its sole button
        // expands the bar; it does not select/reselect a destination. Complete
        // that native interaction before addressing either real tab.
        let collapsed = app.tabBars.buttons.matching(NSPredicate(format: "value CONTAINS %@", "Collapsed")).firstMatch
        if collapsed.exists && collapsed.isHittable {
            collapsed.tap()
            XCTAssertTrue(app.tabBars.buttons[name].waitForExistence(timeout: 10))
        }
        let bottomTab = app.tabBars.buttons[name].firstMatch
        if bottomTab.exists { return bottomTab }

        // iPadOS exposes its adaptive top tabs as native Buttons inside Other,
        // without a TabBar. Constrain the exact label to the real header band;
        // never fall back to a similarly named button inside page content.
        // A native back button can be labeled with the previous page (Settings
        // or Guard). Its stable UIKit identifier distinguishes it from the tab.
        let matches = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", name, "BackButton"))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        // The bottom tab may have mounted during the wait above.
        if bottomTab.exists { return bottomTab }
        let header = app.navigationBars.firstMatch
        let window = app.frame
        let bandBottom = header.exists ? min(header.frame.maxY, window.midY) : window.minY + min(120, window.height / 4)
        let candidates = matches.allElementsBoundByIndex.compactMap { element -> (XCUIElement, CGRect)? in
            let frame = element.frame
            guard frame.width > 0, frame.height > 0, window.contains(frame),
                  frame.minY >= window.minY, frame.maxY <= bandBottom else { return nil }
            return (element, frame)
        }
        guard let first = candidates.first else {
            XCTFail("No native \(name) tab in the top header band: \(app.debugDescription)")
            return matches.firstMatch
        }
        // The observed UIKit hierarchy includes a nested Button duplicate for
        // each tab. Accept only those coincident frames; distinct matches must
        // fail instead of being hidden by an unscoped firstMatch.
        for (_, frame) in candidates.dropFirst() {
            XCTAssertEqual(frame.minX, first.1.minX, accuracy: 0.5)
            XCTAssertEqual(frame.minY, first.1.minY, accuracy: 0.5)
            XCTAssertEqual(frame.width, first.1.width, accuracy: 0.5)
            XCTAssertEqual(frame.height, first.1.height, accuracy: 0.5)
        }
        return first.0
    }
    private func contentBottom(_ app: XCUIApplication) -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        // Only a bottom tab bar occludes the lower viewport. An adaptive top
        // tab strip must not turn a valid iPad content frame into negative height.
        if tabBar.exists, tabBar.frame.minY >= app.frame.midY {
            return tabBar.frame.minY
        }
        return app.frame.maxY
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func retainFrames(_ frames: [String: CGRect], name: String) {
        let values = frames.mapValues { frame in
            ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch { XCTFail("Could not retain measured frames: \(error)") }
    }
    private func recordControlBounds(_ app: XCUIApplication, _ controls: [String: XCUIElement], phase: String) {
        var frames: [String: CGRect] = [:]
        for (name, control) in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 10), name)
            waitForSettledFrame(control, requiresHittable: false)
            let frame = control.frame
            XCTAssertGreaterThan(frame.width, 0, name)
            XCTAssertGreaterThan(frame.height, 0, name)
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(frame), "\(name) must remain on screen: \(frame)")
            frames[name] = frame
        }
        retainFrames(frames, name: phase + " actual accessibility bounds")
    }
    private func assertSameFrames(_ actual: [String: CGRect], _ expected: [String: CGRect], phase: String) {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), phase)
        for (name, frame) in actual {
            guard let baseline = expected[name] else { continue }
            XCTAssertEqual(frame.minX, baseline.minX, accuracy: 1, phase + " " + name + " x")
            XCTAssertEqual(frame.minY, baseline.minY, accuracy: 1, phase + " " + name + " y")
            XCTAssertEqual(frame.width, baseline.width, accuracy: 1, phase + " " + name + " width")
            XCTAssertEqual(frame.height, baseline.height, accuracy: 1, phase + " " + name + " height")
        }
        retainFrames(actual, name: phase)
    }
    private func libraryFrames(_ app: XCUIApplication) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for name in ["Core", "Balanced", "Extra"] {
            let row = app.buttons[name]
            waitForSettledFrame(row, requiresHittable: false)
            frames[name + " accessible row content"] = row.frame
            for (index, text) in row.staticTexts.allElementsBoundByIndex.enumerated() {
                frames[name + " child text \(index)"] = text.frame
            }
        }
        return frames
    }
    private func fullSheetHeader(_ app: XCUIApplication, title: String) -> XCUIElement {
        // RN sheets now use UIKit's real navigation bar. Native task sheets keep
        // their shared SwiftUI header. Resolve the actual owner by its title.
        let navigationBar = app.navigationBars[title]
        if navigationBar.exists { return navigationBar }
        let headers = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["sheet.pinned-header", "full-sheet.header"]))
        // Scope to the actual sheet title: authentication can cover a retained
        // sheet, so querying every header or every Close button is ambiguous.
        // Keep .element: multiple matching owners must fail, not be hidden.
        let legacyHeader = headers.containing(NSPredicate(format: "identifier == %@ AND label == %@",
                                                          "full-sheet.title", title)).element
        // Native service preparation can complete after the initiating tap.
        // Resolve the actual header only after one supported owner appears;
        // an early UIKit miss must not permanently select the legacy query.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            navigationBar.exists || legacyHeader.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       "The presented \(title) sheet must expose its owned header.")
        return navigationBar.exists ? navigationBar : legacyHeader
    }
    private enum SheetControlEdge { case leading, trailing }
    private func assertFullSheetHeaderGeometry(_ header: XCUIElement, button: XCUIElement, edge: SheetControlEdge) {
        if header.elementType == .navigationBar {
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(button.isHittable)
            // Native AX frames describe the visual button, not UIKit's expanded
            // hit region. Do not impose the former custom-circle frame on it.
            XCTAssertGreaterThan(button.frame.width, 0)
            XCTAssertGreaterThan(button.frame.height, 0)
            XCTAssertTrue(header.frame.contains(button.frame))
            return
        }
        // Use only for RN's concrete UIView header. SwiftUI accessibility
        // containers report their children’s union, not the padded layout frame;
        // native header/card spacing is verified in-process and in captures.
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        waitForSettledFrame(button)
        let bounds = header.frame
        let control = button.frame
        // The shared header begins at the presented sheet's safe-content
        // origin. The screen origin includes status-bar/presentation space.
        let top = control.minY - bounds.minY
        let side = edge == .leading ? control.minX - bounds.minX : bounds.maxX - control.maxX
        let geometry = "Sheet header=\(bounds), \(edge) control=\(control), top=\(top), side=\(side)"
        XCTAssertEqual(top, 18, accuracy: 1, geometry)
        XCTAssertEqual(side, 18, accuracy: 1, geometry)
        XCTAssertEqual(top, side, accuracy: 1, geometry)
        XCTAssertEqual(control.width, 44, accuracy: 1, geometry)
        XCTAssertEqual(control.height, 44, accuracy: 1, geometry)
        XCTAssertTrue(bounds.contains(control), geometry)
    }
    private func scrollCustomizationUp(_ app: XCUIApplication) {
        // Keep the gesture outside the slider/segmented-control hit areas.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testOnboardingJapaneseWelcomeWrapsAndWavesMoveInBothMotionModes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launchEnvironment["LAVA_UI_TEST_REPLAY_ONBOARDING"] = "1"
        app.launch()
        let titleQuery = app.staticTexts.matching(identifier: "インターネットは溶岩だらけ")
        XCTAssertTrue(titleQuery.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        // Fabric exposes a paragraph container and its ink as nested static
        // text nodes. Measure the innermost title in either renderer.
        let title = try XCTUnwrap(titleQuery.allElementsBoundByIndex.first {
            $0.children(matching: .staticText).matching(identifier: "インターネットは溶岩だらけ").count == 0
        })
        XCTAssertGreaterThan(title.frame.height, 60, "Japanese headline must wrap rather than truncate.")
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)
        capture(app, "Japanese welcome with fully wrapped heading")
        func wavePixels() throws -> Data {
            let image = app.screenshot().image
            let scale = image.scale
            // A narrow full-height strip away from text/status controls catches all wave edges.
            let rect = CGRect(x: 4 * scale, y: 160 * scale, width: 12 * scale,
                              height: (app.frame.height - 300) * scale)
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
            return try XCTUnwrap(UIImage(cgImage: crop).pngData())
        }
        let before = try wavePixels()
        let tick = expectation(description: "Advance the lava clock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { tick.fulfill() }
        wait(for: [tick], timeout: 2)
        print("LAVA_WELCOME_QA reduceMotion=\(UIAccessibility.isReduceMotionEnabled)")
        XCTAssertNotEqual(try wavePixels(), before, "Welcome waves remain active in both motion modes.")
        capture(app, "Japanese welcome after wave advances")
    }

    func testNativeOnboardingPersistsFallbackChoiceThroughNavigationAndRelaunch() throws {
        // Run on the task-private simulator: completing real onboarding seeds
        // the standard filter library and logging defaults, just as a fresh install does.
        let app = launch()
        func waitForValue(_ element: XCUIElement, _ value: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", value), object: element
            )], timeout: 10), .completed, element.debugDescription)
        }
        func openDNS() -> XCUIElement {
            XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings/dns-resolver")!)
            XCTAssertTrue(app.navigationBars["DNS settings"].waitForExistence(timeout: 10))
            // Use the rendered English catalog values, not the source-key casing.
            let deviceDNS = app.otherElements["dns.tier-toggle.0"].switches.firstMatch
            XCTAssertTrue(deviceDNS.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(deviceDNS.value as? String, "1",
                           "This isolated onboarding journey requires the standard Device DNS primary.")
            let fallback = app.otherElements["dns.tier-toggle.1"].switches.firstMatch
            return fallback
        }
        app.terminate()
        // Seed incomplete onboarding once through the Debug simulator fixture.
        // A launch-argument NO would override the real completion write for the
        // entire process and prevent Open Guard from dismissing the flow.
        // Permissions, configuration actions and animation remain the real ones.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["LAVA_UI_TEST_REPLAY_ONBOARDING"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let primary = app.buttons["onboarding.primary"]
        func expectPage(_ title: String) {
            let heading = title == "Ready" ? app.otherElements["onboarding.ready"] : app.staticTexts[title].firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(primary.waitForExistence(timeout: 10))
            XCTAssertTrue(primary.isHittable)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: primary)], timeout: 10), .completed)
        }
        func advance(to title: String) {
            XCTAssertTrue(primary.isHittable)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
            expectPage(title)
        }
        expectPage("The internet is lava")
        capture(app, "Onboarding animated Lava welcome")
        advance(to: "Lava stands guard here")
        let featureLabel = "Lava blocks your device’s access to malicious domains"
        let feature = app.staticTexts.matching(identifier: featureLabel).allElementsBoundByIndex.first {
            $0.children(matching: .staticText).matching(identifier: featureLabel).count == 0
        } ?? app.staticTexts[featureLabel].firstMatch
        XCTAssertTrue(feature.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(feature)
        retainFrames(["onboarding.surface": app.otherElements["onboarding.surface"].frame,
                      "onboarding.mascot": app.otherElements["onboarding.mascot"].frame,
                      "onboarding.header": app.navigationBars.firstMatch.frame,
                      "onboarding.feature": feature.frame], name: "Onboarding setup geometry")
        capture(app, "Onboarding lava reveals Guard and benefits")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        XCTAssertTrue(app.staticTexts["First, let’s get Lava ready to help."].waitForExistence(timeout: 10))
        let installVPN = app.descendants(matching: .any).matching(identifier: "onboarding.install-vpn").firstMatch
        XCTAssertTrue(installVPN.waitForExistence(timeout: 10))
        if installVPN.isEnabled {
            XCTAssertFalse(primary.isEnabled, "VPN installation gates Next step.")
            installVPN.tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "VPN installed"), object: installVPN
        )], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["onboarding.notifications"].exists)
        capture(app, "Onboarding VPN installed and notifications optional")
        // Skip notification permission by using Next directly after the VPN succeeds.
        advance(to: "Pick how much Lava blocks")
        let core = app.buttons["onboarding.filter.essential"]
        let balanced = app.buttons["onboarding.filter.balanced"]
        XCTAssertTrue(core.isHittable)
        core.tap()
        waitForValue(core, "On")
        waitForValue(balanced, "Off")
        capture(app, "Onboarding protection choice updates immediately")
        balanced.tap()
        waitForValue(balanced, "On")
        waitForValue(core, "Off")
        advance(to: "Lastly, let’s keep your connection running smoothly.")
        let fallback = app.buttons["onboarding.dns-fallback"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "onboarding.dns-fallback").count, 1,
                       "Setup must expose one uniquely addressable fallback control.\n\(app.buttons.debugDescription)")
        for provider in ["Quad9", "Cloudflare", "HaGeZi", "Google"] {
            XCTAssertFalse(app.buttons[provider].exists, "Provider selection belongs in Settings, not onboarding.")
        }
        XCTAssertTrue(app.staticTexts["Change these anytime in Settings."].exists)
        if fallback.value as? String == "Off" { fallback.tap() }
        waitForValue(fallback, "On")
        fallback.tap()
        waitForValue(fallback, "Off")
        let profile = app.buttons["onboarding.dns-profile"]
        if profile.exists {
            waitForValue(profile, "On")
            // Keep the simulator journey independent of system DNS permissions.
            profile.tap()
            waitForValue(profile, "Off")
        }
        capture(app, "Onboarding two optional connection choices")

        let back = app.buttons["Back"]
        XCTAssertTrue(back.isHittable)
        back.tap()
        expectPage("Pick how much Lava blocks")
        waitForValue(balanced, "On")
        advance(to: "Lastly, let’s keep your connection running smoothly.")
        waitForValue(fallback, "Off")
        capture(app, "Onboarding fallback remains off after Back and reentry")
        advance(to: "Ready")
        XCTAssertFalse(app.buttons["onboarding.additional-setup"].exists)
        capture(app, "Onboarding completion with shared smiling mascot")
        back.tap()
        expectPage("Lastly, let’s keep your connection running smoothly.")
        waitForValue(fallback, "Off")
        advance(to: "Ready")
        waitForSettledFrame(app.otherElements["onboarding.mascot"], requiresHittable: false)
        let arrivedMascot = app.otherElements["onboarding.mascot"].frame
        XCTAssertEqual(app.otherElements["onboarding.ready"].value as? String, "Your next step to a safer internet.")
        // External navigation cannot replace the measured Guard under the ready
        // cutout. The same DNS link must work normally after completion below.
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings/dns-resolver")!)
        expectPage("Ready")
        XCTAssertEqual(app.otherElements["onboarding.mascot"].frame, arrivedMascot)
        capture(app, "Ready handoff remains on Guard after a Settings deep link")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: primary)], timeout: 10), .completed)
        primary.tap()
        XCTAssertTrue(primary.waitForNonExistence(timeout: 10), "Open Guard must dismiss the completed native onboarding.")
        XCTAssertTrue(nativeTab(app, "Guard").waitForExistence(timeout: 15))
        let filter = app.buttons["guard.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(filter.label.contains("Balanced"), "Completion must load the selected protection level: \(filter.label)")
        let liveMascot = app.otherElements["guard.mascot"].frame
        print("LAVA_HANDOFF_FRAMES arrived=\(arrivedMascot) live=\(liveMascot)")
        XCTAssertEqual(arrivedMascot.minX, liveMascot.minX, accuracy: 1)
        XCTAssertEqual(arrivedMascot.minY, liveMascot.minY, accuracy: 1)
        XCTAssertEqual(arrivedMascot.width, liveMascot.width, accuracy: 1)
        XCTAssertEqual(arrivedMascot.height, liveMascot.height, accuracy: 1)
        capture(app, "Onboarding opens the real Guard with Balanced protection")
        // With the fallback disabled, the current DNS editor projects only the primary tier.
        XCTAssertTrue(openDNS().waitForNonExistence(timeout: 10))
        capture(app, "Onboarding fallback choice reaches real DNS settings")

        app.terminate()
        // Remove the one-time replay fixture entirely: neither it nor an
        // argument-domain override can mask persisted completion on this launch.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["LAVA_UI_TEST_REPLAY_ONBOARDING"] = nil
        app.launch()
        let guardTab = nativeTab(app, "Guard")
        XCTAssertTrue(guardTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: guardTab
        )], timeout: 10), .completed, "Persisted completion must reveal Guard on a normal launch.")
        XCTAssertFalse(primary.exists)
        XCTAssertTrue(openDNS().waitForNonExistence(timeout: 10))
        capture(app, "Onboarding completion and fallback off persist across normal relaunch")
    }

    func testStoryJourneyLightPreservesConnectionAlignmentAcrossRotation() throws {
        try captureStoryJourney(appearance: "Light")
    }

    func testStoryJourneyDarkPreservesConnectionAlignmentAcrossRotation() throws {
        try captureStoryJourney(appearance: "Dark")
    }

    private func captureStoryJourney(appearance: String) throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        // Select the real persisted native appearance setting. The same app and
        // bridge then render the phone and tablet journeys, without story fixtures.
        nativeTab(app, "Settings").tap()
        let customization = app.buttons["row.Customization"]
        for _ in 0..<4 where !customization.isHittable { app.swipeUp() }
        scrollFullyIntoView(app, customization)
        customization.tap()
        XCTAssertTrue(app.navigationBars["Customization"].waitForExistence(timeout: 10), app.debugDescription)
        let theme = app.segmentedControls["Appearance"].buttons[appearance]
        for _ in 0..<4 where !theme.isHittable { app.swipeUp() }
        XCTAssertTrue(theme.isHittable, app.debugDescription)
        theme.tap()
        let systemSize = app.switches["Match system"]
        for _ in 0..<4 where !systemSize.isHittable { app.swipeUp() }
        XCTAssertTrue(systemSize.isHittable)
        if systemSize.value as? String == "0" { systemSize.tap() }
        nativeTab(app, "Settings").tap()
        nativeTab(app, "Guard").tap()
        let filterSummary = app.buttons["guard.filter"]
        XCTAssertTrue(filterSummary.waitForExistence(timeout: 10))
        let initialSummary = filterSummary.label
        let summaryParts = initialSummary.components(separatedBy: ", ")
        XCTAssertGreaterThanOrEqual(summaryParts.count, 3, initialSummary)
        let identity = summaryParts[1].split(separator: " ", maxSplits: 1).last.map(String.init) ?? summaryParts[1]
        XCTAssertFalse(identity.isEmpty)
        XCTAssertTrue(initialSummary.contains("rules"), "Guard must expose the native warm count beside its filter identity.")
        let device = app.frame.width > 600 ? "iPad" : "iPhone"
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCTAssertTrue(filterSummary.waitForExistence(timeout: 10))
            waitForSettledFrame(filterSummary)
            XCUIDevice.shared.orientation = orientation
            assertWindowOrientation(app, landscape: orientation != .portrait)
            nativeTab(app, "Guard").tap()
            waitForSettledFrame(filterSummary)
            XCTAssertEqual(filterSummary.label, initialSummary, "Rotation cannot replace the accepted filter identity or count.")
            let today = app.buttons["guard.today"]
            XCTAssertTrue(today.isHittable, app.debugDescription)
            let explore = app.buttons["guard.explore"]
            scrollFullyIntoView(app, explore)
            XCTAssertTrue(explore.isHittable)
            capture(app, "\(device) \(appearance) Guard \(name)")

            nativeTab(app, "Settings").tap()
            nativeTab(app, "Settings").tap()
            let settingsContent = app
            let filter = settingsContent.buttons["connection.filter"]
            XCTAssertTrue(filter.waitForExistence(timeout: 10))
            waitForSettledFrame(filter)
            if app.frame.width >= 760 { XCTAssertTrue(filter.label.hasPrefix("Filter, \(identity)\n"), filter.label) }
            else { XCTAssertEqual(filter.label, "Filter") }
            assertConnectionSettingsRows(settingsContent, expanded: app.frame.width >= 760)
            let upgradeID = settingsContent.buttons["row.Get Lava Plus today"].exists ? "row.Get Lava Plus today" : "row.Thank you for using Lava Plus"
            for rowID in ["row.Account & Backup", "row.Customization", upgradeID] {
                let row = settingsContent.buttons[rowID]
                guard row.isHittable else { continue }
                let accessory = settingsContent.descendants(matching: .any).matching(identifier: "\(rowID).accessory").element
                XCTAssertTrue(accessory.waitForExistence(timeout: 10), app.debugDescription)
                let geometry = "\(device) \(appearance) Settings \(name), \(rowID): row=\(row.frame), accessory=\(accessory.frame), app=\(app.frame)"
                XCTAssertEqual(accessory.frame.width, 12, accuracy: 1, "\(geometry)\n\(app.debugDescription)")
                XCTAssertTrue(row.frame.contains(accessory.frame), "The accessory must remain inside its row. \(geometry)\n\(app.debugDescription)")
                XCTAssertGreaterThanOrEqual(accessory.frame.minX, app.frame.minX, "\(geometry)\n\(app.debugDescription)")
                XCTAssertLessThanOrEqual(accessory.frame.maxX, app.frame.maxX, "\(geometry)\n\(app.debugDescription)")
                let visibleTop = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : app.frame.minY
                let visibleBottom = contentBottom(app)
                if row.frame.minY >= visibleTop, row.frame.maxY <= visibleBottom {
                    XCTAssertGreaterThanOrEqual(accessory.frame.minY, visibleTop, "\(geometry)\n\(app.debugDescription)")
                    XCTAssertLessThanOrEqual(accessory.frame.maxY, visibleBottom, "\(geometry)\n\(app.debugDescription)")
                }
            }
            capture(app, "\(device) \(appearance) Settings \(name)")

            let connectionFooter = settingsContent.buttons["Explore this connection"]
            scrollFullyIntoView(app, connectionFooter)
            connectionFooter.tap()
            let destinationPlayback = app.buttons["explore.play"]
            XCTAssertTrue(destinationPlayback.waitForExistence(timeout: 10))
            waitForSettledFrame(destinationPlayback)
            // Native pushes briefly retain the source controller's AX tree.
            // Query the unique destination viewport, not a shared row ID in
            // every controller, and verify the source cannot receive input.
            let exploreContent = scrollView(app, containingButton: "explore.play")
            waitForSettledFrame(exploreContent, requiresHittable: false)
            let sourceSettings = app.scrollViews.containing(.button, identifier: "row.Account & Backup")
            if sourceSettings.count > 0 {
                XCTAssertEqual(sourceSettings.count, 1)
                XCTAssertFalse(sourceSettings.element.buttons["connection.filter"].isHittable)
            }
            let playback = exploreContent.buttons["explore.play"]
            XCTAssertTrue(playback.waitForExistence(timeout: 10))
            XCTAssertTrue(exploreContent.staticTexts["Welcome"].exists)
            XCTAssertFalse(exploreContent.buttons["explore.configure"].exists)
            let exploreFilter = exploreContent.buttons["connection.filter"]
            XCTAssertEqual(exploreFilter.label, "Filter")
            XCTAssertFalse(exploreFilter.isSelected)
            assertConnectionAxis(exploreContent, expectedVertical: false)
            scrollFullyIntoView(app, playback, in: exploreContent, throughGutter: true)
            capture(app, "\(device) \(appearance) Explore \(name)")
            // Playback lifecycle is exercised by the dedicated one-shot demo
            // journey. Here rotation must preserve learning and its real target.
            for _ in 0..<6 where !exploreFilter.isHittable { app.swipeDown() }
            XCTAssertTrue(exploreFilter.isHittable)
            exploreFilter.tap()
            let configure = app.buttons["explore.configure"]
            XCTAssertTrue(configure.waitForExistence(timeout: 10))
            // Play is removed by selection, so reacquire the same destination
            // through its current unique control before querying its rows.
            let selectedExplore = scrollView(app, containingButton: "explore.configure")
            XCTAssertTrue(selectedExplore.buttons["connection.filter"].isSelected)
            XCTAssertFalse(selectedExplore.staticTexts["Welcome"].exists)
            scrollFullyIntoView(app, configure, in: selectedExplore, throughGutter: true)
            XCTAssertEqual(configure.label, "Open Filters")
            configure.tap()
            XCTAssertTrue(app.buttons["row.Now filtering"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["row.Now filtering"].label.contains(identity))
            nativeTab(app, "Settings").tap()
            nativeTab(app, "Guard").tap()
        }
        XCUIDevice.shared.orientation = .portrait
        nativeTab(app, "Settings").tap()
        nativeTab(app, "Settings").tap()
        let plus = app.buttons["row.Get Lava Plus today"].exists ? app.buttons["row.Get Lava Plus today"] : app.buttons["row.Thank you for using Lava Plus"]
        for _ in 0..<4 where !plus.isHittable { app.swipeUp() }
        XCTAssertTrue(plus.isHittable)
        plus.tap()
        XCTAssertTrue(app.navigationBars["Lava Plus"].waitForExistence(timeout: 10))
        capture(app, "\(device) \(appearance) Plus story")
        let carousel = app.descendants(matching: .any).matching(identifier: "carousel.scroll").firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, carousel, throughGutter: true)
        carousel.swipeLeft()
        let connectionScene = app.descendants(matching: .any).matching(identifier: "plus.scene.connection").firstMatch
        XCTAssertTrue(connectionScene.waitForExistence(timeout: 10), app.debugDescription)
        scrollFullyIntoView(app, connectionScene, throughGutter: true)
        let connectionHeading = app.staticTexts["Choose how you connect"].firstMatch
        let connectionCaption = app.staticTexts["Keep the DNS and VPN you trust. Make Lava fit the setup you’ve sweated over."].firstMatch
        XCTAssertTrue(connectionHeading.isHittable)
        XCTAssertTrue(connectionCaption.isHittable)
        XCTAssertTrue(connectionScene.frame.contains(connectionCaption.frame), "The captured scene must include its caption with the illustration.")
        capture(app, "\(device) \(appearance) Plus connection choices")
        carousel.swipeLeft()
        let guardHeading = app.staticTexts["Find your Lava"].firstMatch
        let guardScene = app.descendants(matching: .any).matching(identifier: "plus.scene.guards").firstMatch
        XCTAssertTrue(guardScene.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, guardScene, throughGutter: true)
        XCTAssertTrue(guardHeading.isHittable, "Each Plus benefit must remain reachable before the purchase options.")
        capture(app, "\(device) \(appearance) Plus Guard portraits")
        let restore = app.buttons["Restore purchase"]
        for _ in 0..<8 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable, "The real StoreKit recovery action must remain reachable after the visual story.")
        capture(app, "\(device) \(appearance) Plus purchase area")
        nativeTab(app, "Settings").tap()
        let gallery = app.buttons["row.Design system"]
        for _ in 0..<6 where !gallery.isHittable { app.swipeUp() }
        XCTAssertTrue(gallery.isHittable, app.debugDescription)
        gallery.tap()
        XCTAssertTrue(app.navigationBars["Design system"].waitForExistence(timeout: 10))
        capture(app, "\(device) \(appearance) Design system foundations")
        let circles = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "One circular control")).firstMatch
        XCTAssertTrue(circles.waitForExistence(timeout: 10), app.debugDescription)
        let pendingConfirmation = app.buttons["Confirm pending changes"]
        let noPendingChanges = app.buttons["No pending changes"]
        XCTAssertTrue(pendingConfirmation.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(noPendingChanges.exists, app.debugDescription)
        for _ in 0..<12 where !circles.isHittable || !pendingConfirmation.isHittable { app.swipeUp() }
        XCTAssertTrue(circles.isHittable, "The gallery capture must reach the canonical circular control family.")
        XCTAssertTrue(pendingConfirmation.isHittable)
        XCTAssertTrue(pendingConfirmation.isEnabled)
        XCTAssertFalse(noPendingChanges.isEnabled)
        for control in [pendingConfirmation, noPendingChanges] {
            XCTAssertEqual(control.frame.width, 44, accuracy: 1)
            XCTAssertEqual(control.frame.height, 44, accuracy: 1)
            XCTAssertGreaterThanOrEqual(control.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1)
            XCTAssertLessThanOrEqual(control.frame.maxY, contentBottom(app) + 1)
        }
        capture(app, "\(device) \(appearance) Design system controls")
    }

    private func scrollView(_ app: XCUIApplication, containingButton identifier: String) -> XCUIElement {
        // Retained native routes can expose the same component identifiers.
        // Select the screen by its own action, then require one semantic scope
        // before measuring any shared connection or row components within it.
        let matches = app.scrollViews.containing(.button, identifier: identifier)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(matches.count, 1, "Expected one scroll view containing \(identifier). \(app.debugDescription)")
        return matches.element
    }

    private func assertConnectionSettingsRows(_ content: XCUIElement, expanded: Bool) {
        XCTAssertEqual(content.descendants(matching: .any).matching(identifier: "connection.phone").count > 0, expanded && XCUIApplication().frame.width > XCUIApplication().frame.height)
        for id in ["filter", "vpn", "dns"] {
            let row = content.buttons["connection.\(id)"]
            XCTAssertTrue(row.exists, content.debugDescription)
            let glyph = content.descendants(matching: .any).matching(identifier: "connection.\(id).glyph").element
            let accessory = content.descendants(matching: .any).matching(identifier: "connection.\(id).accessory").element
            XCTAssertTrue(glyph.exists)
            XCTAssertTrue(accessory.exists)
            XCTAssertEqual(glyph.frame.midY, accessory.frame.midY, accuracy: 1, "Each configuration glyph and chevron share the row's center.")
            XCTAssertTrue(row.frame.contains(glyph.frame))
            XCTAssertTrue(row.frame.contains(accessory.frame))
        }
    }

    private func assertConnectionAxis(_ content: XCUIElement, expectedVertical: Bool) {
        let glyphs = ["phone", "filter", "vpn", "dns"].map {
            content.descendants(matching: .any).matching(identifier: "connection.glyph.\($0)").element
        }
        for glyph in glyphs {
            XCTAssertTrue(glyph.waitForExistence(timeout: 10), content.debugDescription)
            XCTAssertEqual(glyph.frame.width, 44, accuracy: 1)
            XCTAssertEqual(glyph.frame.height, 44, accuracy: 1)
        }
        let vertical = content.descendants(matching: .any).matching(identifier: "connection.path.vertical").element.exists
        XCTAssertEqual(vertical, expectedVertical, "The connection must adapt to this viewport, not retain the previous orientation’s layout.")
        for index in 1..<glyphs.count {
            let previous = glyphs[index - 1].frame, current = glyphs[index].frame
            if vertical {
                XCTAssertEqual(current.midX, previous.midX, accuracy: 1, "The bypassed VPN keeps the same vertical axis.")
                XCTAssertGreaterThan(current.midY, previous.midY)
            } else {
                XCTAssertEqual(current.midY, previous.midY, accuracy: 1, "The bypassed VPN keeps the same horizontal axis.")
                XCTAssertGreaterThan(current.midX, previous.midX)
            }
        }
    }

    func testResponsiveColumnsSharePageScrollAndRootHeaderSpace() throws {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        func assertPhysicalHeader(_ title: String) -> CGRect {
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
            waitForSettledFrame(bar, requiresHittable: false)
            var window = CGRect.null
            for element in app.windows.allElementsBoundByIndex {
                let frame = element.frame
                if !frame.isEmpty && (window.isNull || frame.width * frame.height > window.width * window.height) {
                    window = frame
                }
            }
            XCTAssertFalse(window.isNull, "The native header must be measured against an actual app window.")
            XCTAssertEqual(bar.frame.minX, window.minX, accuracy: 1.5,
                           "The native header frame must reach the physical leading edge, outside content safe-area insets.")
            XCTAssertEqual(bar.frame.maxX, window.maxX, accuracy: 1.5,
                           "The native header frame must reach the physical trailing edge.")
            return window
        }
        _ = assertPhysicalHeader("Guard")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: app)], timeout: 15), .completed)
        nativeTab(app, "Settings").tap()
        let left = app.otherElements["story.column.primary"].firstMatch
        let right = app.otherElements["story.column.secondary"].firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 10))
        waitForSettledFrame(left)
        let window = assertPhysicalHeader("Settings")
        XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX)
        let content = app.scrollViews.containing(.button, identifier: "row.Account & Backup").element
        XCTAssertEqual(app.scrollViews.containing(.button, identifier: "row.Account & Backup").count, 1)
        XCTAssertGreaterThanOrEqual(content.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(content.frame.maxX, window.maxX)
        XCTAssertGreaterThan(left.frame.minX, content.frame.minX)
        XCTAssertLessThan(right.frame.maxX, content.frame.maxX,
                          "Both columns must fit inside the full-width scroll viewport, without horizontal content overflow.")
        let beforeLeft = left.frame, beforeRight = right.frame
        content.swipeUp()
        XCTAssertLessThan(left.frame.minY, beforeLeft.minY)
        XCTAssertEqual(left.frame.minY - beforeLeft.minY, right.frame.minY - beforeRight.minY, accuracy: 2)
        capture(app, "Landscape Settings scrolls as one page below its native root header")
        for _ in 0..<4 where !app.buttons["row.Account & Backup"].isHittable { content.swipeDown() }
        app.buttons["row.Account & Backup"].tap()
        _ = assertPhysicalHeader("Account & backup")
        capture(app, "Landscape subpages retain their native title")
        nativeBack(app).tap()
        nativeTab(app, "Guard").tap()
        _ = assertPhysicalHeader("Guard")
        let explore = app.buttons["guard.explore"]
        for _ in 0..<4 where !explore.isHittable { app.swipeUp() }
        explore.tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.scrollViews.containing(.button, identifier: "explore.play").count, 1)
        capture(app, "Landscape Explore columns share a native page scroll")
        nativeBack(app).tap()
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        _ = assertPhysicalHeader("Guard")
    }

    func testExploreDemoAndLearningStaySeparate() throws {
        let app = launch()
        app.buttons["guard.explore"].tap()
        XCTAssertTrue(app.staticTexts["Welcome"].waitForExistence(timeout: 10))
        let device = app.buttons["connection.phone"]
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        waitForSettledFrame(device)
        device.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(device.isSelected)
        let inspectedTitle = app.staticTexts["explore.part.title"]
        XCTAssertTrue(inspectedTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(inspectedTitle.label, "Device")
        XCTAssertEqual(app.staticTexts["explore.part.summary"].label, "This device starts the request.")
        capture(app, "Explore learning uses an outline selection")
        XCTAssertFalse(app.buttons["explore.play"].exists)
        device.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let play = app.buttons["explore.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(app.staticTexts["explore.demo.caption.device"].waitForExistence(timeout: 5))
        XCTAssertFalse(inspectedTitle.exists)
        XCTAssertFalse(app.buttons["explore.configure"].exists)
        capture(app, "Explore playback has its own caption and transport")

        // Main deliberately permits physical inspection to interrupt playback.
        // It must retire that transport and expose only the selected explanation.
        let dns = app.buttons["connection.dns"]
        XCTAssertTrue(dns.waitForExistence(timeout: 5))
        dns.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(dns.isSelected)
        XCTAssertTrue(inspectedTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(inspectedTitle.label, "DNS")
        XCTAssertTrue(app.buttons["explore.transport.play"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["explore.configure"].waitForExistence(timeout: 5))
        capture(app, "Physical DNS inspection retires the playing lesson")
        dns.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let pause = app.buttons["explore.transport.play"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertEqual(pause.label, "Resume demo")
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let total = try XCTUnwrap(Int(counter.label.split(separator: "/").last.map(String.init) ?? ""))
        XCTAssertGreaterThan(total, 1)
        XCTAssertEqual(counter.label, "1/\(total)")
        let next = app.buttons["explore.next"]
        let blockedCaption = app.staticTexts["explore.demo.caption.blocked-stop"]
        var observedBlockedExplanation = false
        for _ in 1..<total {
            next.tap()
            if blockedCaption.exists {
                observedBlockedExplanation = true
                capture(app, "Explore explains the blocked lookup at the filter")
            }
        }
        XCTAssertTrue(observedBlockedExplanation, "The lesson must include the blocked request stopping before DNS.")
        XCTAssertEqual(counter.label, "\(total)/\(total)")
        XCTAssertTrue(app.staticTexts["explore.demo.caption.ending"].waitForExistence(timeout: 5))
        XCTAssertFalse(inspectedTitle.exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["Explore the steps"].waitForExistence(timeout: 5))
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(play.label, "Play again")
        XCTAssertTrue(app.staticTexts["Tap a step to see what it does."].exists)
        capture(app, "Explore completion offers the next learning step")
        let filter = app.buttons["connection.filter"]
        scrollFullyIntoView(app, filter, throughGutter: true)
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(filter.isSelected)
        XCTAssertTrue(app.buttons["explore.configure"].exists)
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        nativeBack(app).tap()
        let explore = app.buttons["guard.explore"]
        waitForSettledFrame(explore)
        explore.tap()
        XCTAssertTrue(app.staticTexts["Welcome"].waitForExistence(timeout: 10))
        XCTAssertTrue(play.exists)
        XCTAssertFalse(app.buttons["explore.transport.play"].exists)
    }

    func testExploreTransportScrubsAndPauses() throws {
        let app = launch(delayedQueries: true)
        app.buttons["guard.explore"].tap()
        app.buttons["explore.play"].tap()
        let transport = app.descendants(matching: .any).matching(identifier: "explore.transport").firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        let playPause = app.buttons["explore.transport.play"]
        XCTAssertEqual(playPause.label, "Pause demo")
        playPause.tap()
        let next = app.buttons["explore.next"]
        XCTAssertTrue(next.exists)
        next.tap()
        // The current transport uses Previous/Next and a step count. Advance
        // once and retain that paused visible step, rather than a removed slider.
        let step = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        XCTAssertTrue(transport.frame.contains(step.frame), "The flattened count must still belong geometrically to its transport.")
        XCTAssertEqual(playPause.label, "Resume demo")
        let scrubbed = step.label
        let position = scrubbed.split(separator: "/").compactMap { Int($0) }
        XCTAssertEqual(position.count, 2)
        XCTAssertGreaterThan(position[0], 1)
        XCTAssertLessThan(position[0], position[1], "One forward step must not jump to the last scene.")
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in step.label != scrubbed }, object: step)
        advanced.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 3), .completed, "Advancing a step leaves the lesson paused.")
        scrollFullyIntoView(app, step)
        let stepPixels = acceptedPixelRegion(app, element: step, name: "Explore paused step")
        capture(app, "Explore accepted paused transport step before Home")
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
        app.activate()
        assertSecurityOffResumeRetainsAcceptedValues(app, page: "Explore", resume: 1,
            acceptedValues: [(step, scrubbed)], acceptedPixels: [stepPixels]) {
                XCTAssertEqual(playPause.label, "Resume demo",
                              "Security-off resume must preserve the paused lesson's controls.")
            }
        playPause.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in step.label != scrubbed }, object: step
        )], timeout: 10), .completed)
        XCTAssertEqual(playPause.label, "Pause demo")
        playPause.tap()
        XCTAssertEqual(playPause.label, "Resume demo")
        capture(app, "Explore resumed then paused without changing the layout")
        nativeBack(app).tap()
    }

    func testExploreFlowchartPhysicalTapsAndDragging() throws {
        let app = launch()
        app.buttons["guard.explore"].tap()
        let filter = app.buttons["connection.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        waitForSettledFrame(filter)
        // A real coordinate tap exercises responder arbitration; direct JS
        // onPress tests can conceal an intercepted physical touch.
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in filter.isSelected }, object: filter
        )], timeout: 5), .completed, "A physical flowchart tap must select its step.")
        XCTAssertTrue(app.buttons["explore.configure"].exists)
        capture(app, "Explore physical tap selects Filter")
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(filter.isSelected, "A second tap clears inspection.")
        let phone = app.buttons["connection.phone"]
        let dns = app.buttons["connection.dns"]
        let before = phone.frame
        phone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: dns.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(dns.isSelected, "Dragging must select the final step without a second release tap.")
        XCTAssertEqual(phone.frame.minY, before.minY, accuracy: 2, "Inspecting the flowchart must not scroll its page.")
        capture(app, "Explore physical drag selects DNS without page scrolling")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in filter.isSelected }, object: filter
        )], timeout: 5), .completed, "Inspection must resume after background/foreground.")
        nativeBack(app).tap()
        app.buttons["guard.explore"].tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in filter.isSelected }, object: filter
        )], timeout: 5), .completed, "Inspection must work when the page is reopened.")
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["explore.play"].tap()
        // A touch during playback switches directly to inspection.
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(filter.isSelected)
        XCTAssertFalse(app.buttons["explore.next"].exists)
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["explore.play"].tap()
        app.buttons["explore.transport.play"].tap()
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let total = try XCTUnwrap(Int(counter.label.split(separator: "/").last.map(String.init) ?? ""))
        for _ in 1..<total { app.buttons["explore.next"].tap() }
        XCTAssertEqual(counter.label, "\(total)/\(total)")
        XCTAssertTrue(app.buttons["explore.next"].isEnabled)
        app.buttons["explore.next"].tap()
        XCTAssertTrue(app.buttons["Play again"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["explore.next"].exists)
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(filter.isSelected, "Inspection remains available after finishing the demo.")
        capture(app, "Explore inspection works after final Next ends the demo")
    }

    func testExploreLargeTextPhysicalInspection() throws {
        let app = launch(largeText: true)
        let explore = app.buttons["guard.explore"]
        if !explore.isHittable { app.swipeUp() }
        XCTAssertTrue(explore.waitForExistence(timeout: 10))
        explore.tap()
        let phone = app.buttons["connection.phone"]
        let filter = app.buttons["connection.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        waitForSettledFrame(filter)
        XCTAssertGreaterThan(filter.frame.midY, phone.frame.midY)
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(filter.isSelected)
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let before = phone.frame
        phone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(filter.isSelected)
        XCTAssertEqual(phone.frame.minY, before.minY, accuracy: 2)
        capture(app, "Explore large text vertical touch inspection")
    }

    func testDomainSearchKeyboardDoesNotLiftNativeTabBar() throws {
        let app = launch()
        app.buttons["guard.today"].tap()
        for name in ["row.Top domains", "row.Domain History"] {
            waitForSettledFrame(app.buttons[name])
            app.buttons[name].tap()
            // Latest main owns search in UISearchController, above the shared
            // body. Its captured UIKit hierarchy exposes a SearchField.
            let search = app.searchFields["Search domains"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            XCTAssertEqual(search.placeholderValue, "Search domains")
            let tabs = app.tabBars.firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 5))
            waitForSettledFrame(tabs)
            let before = tabs.frame
            search.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            search.typeText("example")
            if tabs.exists {
                XCTAssertEqual(tabs.frame.minY, before.minY, accuracy: 2,
                               "Keyboard avoidance must not move the native tab controller.")
                XCTAssertGreaterThan(tabs.frame.midY, keyboard.frame.minY,
                                     "The keyboard must cover the bottom tabs instead of lifting them.")
            }
            XCTAssertFalse(app.tabBars.buttons["Settings"].isHittable)
            capture(app, "Domain search keyboard covers stationary tabs")
            // UISearchController owns dismissal while its presentation hides
            // the title. Current UIKit uses a Close glyph; earlier versions
            // expose Cancel. Require exactly one native dismissal action.
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"]))
            XCTAssertEqual(cancel.count, 1, app.debugDescription)
            XCTAssertTrue(cancel.firstMatch.waitForExistence(timeout: 5))
            cancel.firstMatch.tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
            XCTAssertTrue(nativeBack(app).waitForExistence(timeout: 5))
            waitForSettledFrame(nativeBack(app))
            nativeBack(app).tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.tabBars.firstMatch.frame.minY, before.minY, accuracy: 2)
        }
    }

    func testDomainSelectorsAreVisibleOnFirstEntryAndReentry() throws {
        let app = launch()
        app.buttons["guard.today"].tap()
        for name in ["row.Top domains", "row.Domain History", "row.Top domains"] {
            // A hittable accessibility snapshot can precede completion of the
            // parent native push. Settle that destination before the next tap.
            waitForSettledFrame(app.buttons[name])
            app.buttons[name].tap()
            let show = app.segmentedControls["Show"]
            XCTAssertTrue(show.waitForExistence(timeout: 10))
            XCTAssertTrue(show.buttons["All"].isSelected)
            // Exercise UIKit tracking without imposing a custom lens appearance.
            show.buttons["All"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: show.buttons["Blocked"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 1)
            XCTAssertTrue(show.buttons["Blocked"].isSelected)
            show.buttons["Blocked"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: show.buttons["All"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 1)
            XCTAssertTrue(show.buttons["All"].isSelected)
            XCTAssertFalse(app.staticTexts["Blocked"].exists)
            capture(app, "Domain Show keeps All Allowed Blocked visible on entry")
            nativeBack(app).tap()
        }
    }

    func testNativeSegmentedSelectionAndCustomReselect() throws {
        print("LAVA_SEGMENT_REVIEW reduce=\(UIAccessibility.isReduceMotionEnabled) crossFade=\(UIAccessibility.prefersCrossFadeTransitions)")
        let app = launch()
        app.buttons["guard.today"].tap()
        let periods = app.segmentedControls["activity.period"]
        XCTAssertTrue(periods.waitForExistence(timeout: 10))
        waitForSettledFrame(periods)

        func drag(_ control: XCUIElement, from: String, to: String) {
            // Slow movement and a held endpoint make the pre-release visual
            // state reviewable in the run's recording. Final selection alone
            // cannot prove that the native thumb followed the finger.
            control.buttons[from].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2,
                       thenDragTo: control.buttons[to].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 2)
        }
        drag(periods, from: "Today", to: "Month")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in periods.buttons["Month"].isSelected }, object: nil
        )], timeout: 10), .completed)
        drag(periods, from: "Month", to: "Today")
        XCTAssertTrue(periods.buttons["Today"].isSelected)

        drag(periods, from: "Today", to: "Custom")
        let calendar = app.navigationBars["Custom dates"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10))
        calendar.buttons["Apply"].tap()
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 10))
        XCTAssertTrue(periods.buttons["Custom"].isSelected)
        waitForSettledFrame(periods)
        periods.buttons["Custom"].tap()
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "The accepted Custom segment still reopens its editor once.")
        calendar.buttons["Cancel"].tap()
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 10))
        XCTAssertTrue(periods.buttons["Custom"].isSelected)
        capture(app, "Activity native selector retains accepted Custom after cancellation")

        nativeBack(app).tap()
        nativeTab(app, "Settings").tap()
        waitForSettledFrame(app.buttons["row.Customization"])
        app.buttons["row.Customization"].tap()
        let appearance = app.segmentedControls["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        waitForSettledFrame(appearance)
        let original = appearance.buttons.matching(NSPredicate(format: "selected == true")).element.label
        drag(appearance, from: original, to: original == "Dark" ? "Light" : "Dark")
        XCTAssertTrue(appearance.buttons[original == "Dark" ? "Light" : "Dark"].isSelected)
        capture(app, "Appearance shares native segmented drag feedback")
        appearance.buttons[original].tap()
        XCTAssertTrue(appearance.buttons[original].isSelected)
    }

    func testExplicitCrossFadeNavigation() throws {
        // This opt-in comparison requires the actual UIKit preference on the
        // separate QA simulator. Never infer it from a guessed defaults key.
        guard UIAccessibility.prefersCrossFadeTransitions else {
            throw XCTSkip("Enable Prefer Cross-Fade Transitions on the QA simulator for this comparison.")
        }
        try reviewNavigationMotion()
    }

    func testGuardFilterNativeTitleTransitions() throws {
        try checkGuardFilterNativeTitleTransitions(launch())
    }

    func testGuardFilterNativeTitleTransitionsDark() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Customization"].tap()
        let dark = app.segmentedControls["Appearance"].buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 10))
        dark.tap()
        nativeTab(app, "Guard").tap()
        try checkGuardFilterNativeTitleTransitions(app)
    }

    private func checkGuardFilterNativeTitleTransitions(_ app: XCUIApplication) throws {
        let filterTile = app.buttons["guard.filter"]
        XCTAssertTrue(filterTile.waitForExistence(timeout: 10))
        filterTile.tap()
        let filters = app.navigationBars["Filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 10))
        XCTAssertTrue(filters.staticTexts["Filters"].exists)
        capture(app, "Guard to Filters native title")
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.45)).withOffset(CGVector(dx: 2, dy: 0))
        // A slow, held short edge gesture exposes the intermediate title in the
        // recording and must cancel without losing the destination navigation item.
        origin.press(forDuration: 0.1,
                     thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)),
                     withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 1)
        XCTAssertTrue(filters.waitForExistence(timeout: 10))
        XCTAssertTrue(filters.staticTexts["Filters"].exists)
        origin.press(forDuration: 0.1,
                     thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)),
                     withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 1)
        XCTAssertTrue(app.navigationBars["Guard"].waitForExistence(timeout: 10))
        filterTile.tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 10))
        nativeBack(app).tap()
        XCTAssertTrue(app.navigationBars["Guard"].waitForExistence(timeout: 10))
        capture(app, "Guard title restored after native back")
    }

    func testNavigationMotionReview() throws { try reviewNavigationMotion() }
    private func reviewNavigationMotion() throws {
        print("LAVA_MOTION_REVIEW reduce=\(UIAccessibility.isReduceMotionEnabled) crossFade=\(UIAccessibility.prefersCrossFadeTransitions)")
        let app = launch()
        nativeTab(app, "Settings").tap()
        XCTAssertTrue(app.buttons["row.Account & Backup"].waitForExistence(timeout: 10))
        nativeTab(app, "Guard").tap()
        app.buttons["guard.today"].tap()
        XCTAssertTrue(app.segmentedControls["activity.period"].waitForExistence(timeout: 10))
        nativeBack(app).tap()
        app.buttons["guard.today"].tap()
        let screen = app.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: screen.height * 0.45))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(app.buttons["guard.today"].waitForExistence(timeout: 10))
        app.buttons["guard.filter"].tap()
        let item = app.navigationBars.buttons["Import"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(item.frame.width, item.frame.height, "The native Import item includes its visible title.")
        capture(app, "Native labelled Import toolbar")
        app.buttons["row.Now filtering"].tap()
        capture(app, "Native filter toolbar group after push")
        nativeBack(app).tap()
        item.tap()
        app.buttons["Enter a code"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        capture(app, "Native import code navigation")
        app.navigationBars["Enter a code"].buttons["Back"].tap()
        XCTAssertTrue(app.buttons["Enter a code"].waitForExistence(timeout: 10))
        capture(app, "Native import menu navigation")
    }

    func testActivityChartsPageAndClearInspection() throws {
        let app = launch()
        app.buttons["guard.today"].tap()
        let periods = app.segmentedControls["activity.period"]
        XCTAssertTrue(periods.waitForExistence(timeout: 10))
        // Drag the native selection, rather than tapping a replacement control.
        periods.buttons["Today"].press(forDuration: 0.1, thenDragTo: periods.buttons["Month"])
        XCTAssertTrue(periods.buttons["Month"].isSelected)
        let cycle = app.buttons["activity.chart.next"]
        let overview = app.descendants(matching: .any).matching(identifier: "activity.plot.total").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        let height = overview.frame.height
        let totalBar = app.descendants(matching: .any).matching(identifier: "activity.total.inspect").firstMatch
        let totalValue = app.descendants(matching: .any).matching(identifier: "activity.total.value").firstMatch
        XCTAssertTrue(totalBar.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(totalValue.waitForExistence(timeout: 10), app.debugDescription)
        let totalBaseline = totalBar.frame.maxY
        XCTAssertEqual(totalValue.frame.midY, (cycle.frame.maxY + totalBar.frame.minY) / 2, accuracy: 1.5,
                       "The count is centered between the title pill and the actual composition bar.")
        let aggregate = totalValue.label
        totalBar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(totalValue.label, aggregate, "Outcome inspection must retain the aggregate count.")
        capture(app, "Activity Total portion inspection retains aggregate")
        app.descendants(matching: .any).matching(identifier: "legend.allowed").firstMatch.tap()
        XCTAssertFalse((totalBar.value as? String ?? "").contains("Allowed"))
        XCTAssertFalse((totalBar.value as? String ?? "").contains("Blocked"))
        cycle.tap()
        let counts = app.descendants(matching: .any).matching(identifier: "activity.plot.counts").firstMatch
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        XCTAssertEqual(counts.frame.height, height, accuracy: 1)
        let baseline = app.descendants(matching: .any).matching(identifier: "activity.baseline").firstMatch
        XCTAssertTrue(baseline.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(baseline.frame.maxY, totalBaseline, accuracy: 1.5,
                       "Total lower border and the time-chart x-axis share one actual baseline.")
        let plotY = counts.frame.minY
        counts.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.75)).press(forDuration: 0.1,
            thenDragTo: counts.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.15)))
        XCTAssertEqual(counts.frame.minY, plotY, accuracy: 1.5, "Inspection owns the gesture and locks page scrolling.")
        XCTAssertNotEqual(counts.value as? String, "Drag to inspect")
        capture(app, "Activity absolute counts drag inspection")
        app.descendants(matching: .any).matching(identifier: "legend.allowed").firstMatch.tap()
        XCTAssertEqual(counts.value as? String, "Drag to inspect", "Tapping a legend resets inspection without cycling the chart.")
        counts.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(counts.value as? String, "Drag to inspect", "A new chart touch inspects again after reset.")
        cycle.tap()
        let rate = app.descendants(matching: .any).matching(identifier: "activity.plot.rate").firstMatch
        XCTAssertTrue(rate.waitForExistence(timeout: 10))
        XCTAssertEqual(rate.frame.height, height, accuracy: 1)
        XCTAssertEqual(baseline.frame.maxY, totalBaseline, accuracy: 1.5)
        XCTAssertEqual(rate.value as? String, "Drag to inspect")
        rate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(rate.value as? String, "Drag to inspect")
        capture(app, "Activity blocked rate inspection")
        app.descendants(matching: .any).matching(identifier: "legend.blocked").firstMatch.tap()
        XCTAssertEqual(rate.value as? String, "Drag to inspect")
        rate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(rate.value as? String, "Drag to inspect")
        periods.buttons["7 days"].tap()
        XCTAssertEqual(rate.value as? String, "Drag to inspect")
        cycle.tap()
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        XCTAssertEqual(overview.frame.height, height, accuracy: 1)
        capture(app, "Activity overview shares the same chart frame")
    }

    func testActivityColdPeriodsAndCustomDraftStayStable() throws {
        let app = launch(delayedQueries: true)
        app.buttons["guard.today"].tap()
        let periods = app.segmentedControls["activity.period"]
        XCTAssertTrue(periods.waitForExistence(timeout: 15))
        let digest = app.descendants(matching: .any).matching(identifier: "activity.digest").firstMatch
        let caption = app.staticTexts["activity.caption.text"]
        XCTAssertTrue(digest.waitForExistence(timeout: 15))
        func waitForLoaded() {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                caption.exists && caption.label != "Loading Activity…"
            }, object: caption)], timeout: 20), .completed)
        }
        waitForLoaded()
        let original = digest.frame
        var observations: [String] = []
        for title in ["7 days", "Month", "Today"] {
            periods.buttons[title].tap()
            XCTAssertTrue(periods.buttons[title].isSelected)
            if title != "Today" {
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    caption.exists && caption.label == "Loading Activity…"
                }, object: caption)], timeout: 3), .completed, "An uncached range must expose pending feedback.")
                observations.append("\(title) pending: digest=\(digest.frame), caption=\(caption.frame)")
                XCTAssertEqual(digest.frame.height, original.height, accuracy: 1)
                XCTAssertEqual(digest.frame.minY, original.minY, accuracy: 1)
                capture(app, "Activity \(title) pending without panel resize")
            }
            waitForLoaded()
            observations.append("\(title) settled: digest=\(digest.frame), caption=\(caption.frame)")
            XCTAssertEqual(digest.frame.height, original.height, accuracy: 1)
            XCTAssertEqual(digest.frame.minY, original.minY, accuracy: 1)
            capture(app, "Activity \(title) settled without panel resize")
        }
        let receipt = XCTAttachment(string: observations.joined(separator: "\n"))
        receipt.name = "Activity cold-period geometry"
        receipt.lifetime = .keepAlways
        add(receipt)
        let custom = periods.buttons["Custom"]
        let editor = app.navigationBars["Custom dates"]
        custom.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        // Modal accessibility can hide the underlying segmented control. The
        // retained screenshot qualifies its visible draft selection separately.
        let start = app.datePickers["activity.date.start"]
        let end = app.datePickers["activity.date.end"]
        XCTAssertTrue(start.exists); XCTAssertTrue(end.exists)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium; formatter.timeStyle = .none
        let today = Calendar.current.startOfDay(for: Date())
        let fortnightStart = Calendar.current.date(byAdding: .day, value: -13, to: today)!
        let expectedDates = "Expected inclusive fortnight: \(formatter.string(from: fortnightStart)) through \(formatter.string(from: today))"
        let datesEvidence = XCTAttachment(string: expectedDates + "\n" + start.debugDescription + "\n" + end.debugDescription)
        datesEvidence.name = "Activity Custom native date controls"
        datesEvidence.lifetime = .keepAlways
        add(datesEvidence)
        capture(app, "Activity Custom remains selected with fourteen-day draft")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertTrue(periods.buttons["Today"].isSelected)
        custom.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.buttons["Apply"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertTrue(custom.isSelected)
        let accepted = app.staticTexts["activity.custom-range"]
        XCTAssertTrue(accepted.waitForExistence(timeout: 10))
        let acceptedLabel = accepted.label
        custom.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        capture(app, "Activity reopened Custom retains fourteen-day dates")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertTrue(custom.isSelected)
        XCTAssertEqual(accepted.label, acceptedLabel)
        capture(app, "Activity accepted Custom survives reopen and cancel")
    }

    func testActivityDigestKeepsItsGeometryAcrossChildPages() throws {
        let app = launch()
        app.buttons["guard.today"].tap()
        let digest = app.descendants(matching: .any).matching(identifier: "activity.digest").firstMatch
        XCTAssertTrue(digest.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(digest)
        let frame = digest.frame
        for name in ["row.Top domains", "row.Domain History", "row.Top domains"] {
            app.buttons[name].tap()
            let back = nativeBack(app)
            XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
            back.tap()
            XCTAssertTrue(digest.waitForExistence(timeout: 10))
            XCTAssertEqual(digest.frame.height, frame.height, accuracy: 1.5)
            waitForSettledFrame(digest)
            XCTAssertEqual(digest.frame.minY, frame.minY, accuracy: 1.5)
        }
        capture(app, "Activity retains its digest through child navigation")

        // The identifier belongs to the actual UISegmentedControl, so accepted
        // selection can be checked without interpreting a React wrapper's value.
        let periods = app.segmentedControls["activity.period"]
        XCTAssertTrue(periods.waitForExistence(timeout: 10), app.debugDescription)
        let customRanges = app.staticTexts.matching(identifier: "activity.custom-range")
        let customRange = customRanges.element
        func choosePeriod(_ title: String) {
            let button = periods.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in button.isSelected }, object: button
            )], timeout: 10), .completed, "The native calendar preset must be accepted before continuing.")
            XCTAssertEqual(periods.buttons.matching(NSPredicate(format: "selected == true")).count, 1)
            XCTAssertFalse(customRange.exists, "A preset must not duplicate its range in the custom-date summary.")
        }
        for title in ["7 days", "Month", "Today"] {
            choosePeriod(title)
            capture(app, "Activity \(title) calendar preset")
        }

        choosePeriod("Month")
        XCTAssertFalse(app.navigationBars["Activity"].buttons["Change activity dates"].exists)
        let custom = periods.buttons["Custom"]
        let calendar = app.navigationBars["Custom dates"]
        custom.tap()
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.datePickers["activity.date.start"].exists)
        XCTAssertTrue(app.datePickers["activity.date.end"].exists)
        capture(app, "Activity native start and end date editor")
        calendar.buttons["Cancel"].tap()
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 10))
        XCTAssertTrue(periods.buttons["Month"].isSelected)
        XCTAssertFalse(customRange.exists)
        custom.tap()
        XCTAssertTrue(calendar.waitForExistence(timeout: 10))
        calendar.buttons["Apply"].tap()
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 10))
        XCTAssertTrue(customRange.waitForExistence(timeout: 10))
        XCTAssertTrue(custom.isSelected)
        XCTAssertEqual(customRanges.count, 1)
        let acceptedLabel = customRange.label
        custom.tap()
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "The selected Custom segment must reopen its editor.")
        calendar.buttons["Cancel"].tap()
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 10))
        XCTAssertEqual(customRange.label, acceptedLabel)
        XCTAssertTrue(custom.isSelected)
        capture(app, "Activity retains custom dates after reopening and cancellation")
        choosePeriod("Today")

        let activityHeader = app.navigationBars["Activity"]
        nativeBack(app).tap()
        XCTAssertTrue(activityHeader.waitForNonExistence(timeout: 10))
        let today = app.buttons["guard.today"]
        XCTAssertTrue(today.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(today.isHittable)
        capture(app, "Activity ordinary Back returns to Guard")

        today.tap()
        XCTAssertTrue(activityHeader.waitForExistence(timeout: 10))
        XCTAssertTrue(digest.waitForExistence(timeout: 10))
        waitForSettledFrame(digest)
        let reopenedFrame = digest.frame
        // Release a short edge drag after holding it still: distance stays
        // below the interactive-pop threshold without a fast flick completing it.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
        edge.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.55)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(activityHeader.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(digest)
        XCTAssertEqual(app.navigationBars.matching(identifier: "Activity").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "activity.digest").count, 1)
        XCTAssertEqual(digest.frame.minX, reopenedFrame.minX, accuracy: 1.5)
        XCTAssertEqual(digest.frame.minY, reopenedFrame.minY, accuracy: 1.5)
        XCTAssertEqual(digest.frame.width, reopenedFrame.width, accuracy: 1.5)
        XCTAssertEqual(digest.frame.height, reopenedFrame.height, accuracy: 1.5)
        XCTAssertTrue(periods.buttons["Today"].isSelected)
        capture(app, "Activity remains intact after a cancelled edge swipe")

        edge.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.55)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(activityHeader.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        XCTAssertTrue(today.isHittable)
        XCTAssertFalse(digest.exists)
        capture(app, "Activity completed edge swipe returns to Guard")
    }

    func testGuardActivityReturnsAfterBackgroundAndTabChanges() throws {
        let app = launch(delayedQueries: true)
        let activity = app.buttons["guard.today"]
        let filter = app.buttons["guard.filter"]
        let status = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Protection status")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(filter.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        let originalStatus = status.value as? String ?? ""
        XCTAssertTrue(originalStatus.lowercased().hasPrefix("protection off."),
                      "This isolated journey must keep Guard off and must never start a VPN.")
        let originalToday = activity.label
        let originalFilter = filter.label
        XCTAssertFalse(originalToday.contains("—"), "Guard must start with accepted summary content.")
        let todayPixels = acceptedPixelRegion(app, element: activity, name: "Guard Today summary")
        let filterPixels = acceptedPixelRegion(app, element: filter, name: "Guard filter summary")
        let statusPixels = acceptedPixelRegion(app, element: status, name: "Guard accepted Off panel")
        capture(app, "Guard Security off accepted panel and summaries before Home")
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
        app.activate()
        assertSecurityOffResumeRetainsAcceptedValues(app, page: "Guard", resume: 1,
            acceptedValues: [(activity, originalToday), (filter, originalFilter)],
            acceptedPixels: [todayPixels, filterPixels, statusPixels]) {
                XCTAssertEqual(status.value as? String, originalStatus,
                               "Guard must retain its accepted Off panel across resume.")
                XCTAssertTrue(app.navigationBars["Guard"].exists)
            }
        for cycle in 0..<3 {
            XCTAssertTrue(activity.waitForExistence(timeout: 10), app.debugDescription)
            activity.tap()
            let digest = app.descendants(matching: .any).matching(identifier: "activity.digest").firstMatch
            XCTAssertTrue(digest.waitForExistence(timeout: 10), app.debugDescription)
            if cycle == 1 {
                let total = app.descendants(matching: .any).matching(identifier: "activity.total.value").firstMatch
                let totalInspector = app.descendants(matching: .any).matching(identifier: "activity.total.inspect").firstMatch
                let caption = app.staticTexts["activity.caption.text"]
                let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    guard total.exists && totalInspector.exists && caption.exists else { return false }
                    let value = totalInspector.value as? String ?? ""
                    return !value.isEmpty
                        && value != "No data" && !value.contains("Loading")
                        && caption.exists && caption.label != "Loading Activity…" && caption.label != "—"
                }, object: total)
                XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed,
                               "The journey must retain an accepted count, including a legitimate zero.")
                let originalTotal = totalInspector.value as? String ?? ""
                let originalInspectorLabel = totalInspector.label
                let originalCaption = caption.label
                let totalPixels = acceptedPixelRegion(app, element: total, name: "Activity accepted total number")
                let captionPixels = acceptedPixelRegion(app, element: caption, name: "Activity accepted caption")
                for resume in 1...3 {
                    XCUIDevice.shared.press(.home)
                    let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        app.state == .runningBackground || app.state == .runningBackgroundSuspended
                    }, object: app)
                    XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
                    app.activate()
                    assertSecurityOffResumeRetainsAcceptedValues(app, page: "Activity", resume: resume,
                        acceptedValues: [(totalInspector, originalInspectorLabel), (caption, originalCaption)],
                        acceptedPixels: [totalPixels, captionPixels]) {
                            XCTAssertEqual(totalInspector.value as? String, originalTotal)
                        }
                    XCTAssertTrue(digest.exists, "Resume must retain the Activity panel immediately.")
                    XCTAssertTrue(app.navigationBars["Activity"].exists,
                                  "Resuming must retain the Activity route.")
                }
            }
            if cycle == 2 {
                app.tabBars.buttons["Settings"].tap()
                app.tabBars.buttons["Guard"].tap()
            }
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
            back.tap()
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: activity)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        }
        capture(app, "Guard Activity returns through native Back after lifecycle changes")
    }

    func testDiagnosticPagesRetainAcceptedContentDuringDelayedForegroundReads() throws {
        let app = launch(delayedQueries: true)
        nativeTab(app, "Settings").tap()
        let stats = app.buttons["row.Nerd stats"]
        for _ in 0..<4 where !stats.isHittable { app.swipeUp() }
        stats.tap()
        let version = app.descendants(matching: .any).matching(identifier: "diagnostic.Version").firstMatch
        let loaded = NSPredicate(format: "label BEGINSWITH %@ AND NOT (label CONTAINS %@)", "Version, ", "Loading")
        expectation(for: loaded, evaluatedWith: version)
        waitForExpectations(timeout: 20)
        let original = version.label
        XCTAssertFalse(original.contains("—"), "The baseline must be a loaded Version value.")
        let versionPixels = acceptedPixelRegion(app, element: version, name: "Nerd Stats accepted Version")
        for resume in 1...2 {
            XCUIDevice.shared.press(.home)
            let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
            app.activate()
            assertSecurityOffResumeRetainsAcceptedValues(app, page: "Nerd Stats", resume: resume,
                acceptedValues: [(version, original)], acceptedPixels: [versionPixels])
        }
        capture(app, "Nerd Stats retains loaded values after app switching")
        nativeBack(app).tap()
        let network = app.buttons["row.Network activity"]
        for _ in 0..<3 where !network.isHittable { app.swipeUp() }
        network.tap()
        let loadedNetwork = app.descendants(matching: .any).matching(identifier: "network.loaded").firstMatch
        XCTAssertTrue(loadedNetwork.waitForExistence(timeout: 20), app.debugDescription)
        let originalNetworkLabel = loadedNetwork.label
        let networkPixels = acceptedPixelRegion(app, element: loadedNetwork, name: "Network Activity accepted visible log")
        XCUIDevice.shared.press(.home)
        let networkBackgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [networkBackgrounded], timeout: 10), .completed)
        app.activate()
        assertSecurityOffResumeRetainsAcceptedValues(app, page: "Network Activity", resume: 1,
            acceptedValues: [(loadedNetwork, originalNetworkLabel)], acceptedPixels: [networkPixels]) {
                XCTAssertTrue(loadedNetwork.exists, "An accepted log must also survive the pending foreground refresh.")
                XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "network.pending").firstMatch.exists)
            }
        capture(app, "Network Activity retains accepted content after app switching")
    }

    func testProtectedNerdStatsKeepsCoverUntilDelayedForegroundReadSettles() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic app passcode and delayed query qualification is simulator-only.")
        #else
        let app = launch(delayedQueries: true)
        assertRound8GuardIsOff(app)
        nativeTab(app, "Settings").tap()
        let securityRow = app.buttons["row.Security"]
        scrollFullyIntoView(app, securityRow)
        securityRow.tap()
        let passcode = app.switches["Passcode"]
        func waitForValue(_ element: XCUIElement, _ expected: String) {
            let accepted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                element.exists && element.value as? String == expected
            }, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 10), .completed)
        }
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        XCTAssertEqual(passcode.value as? String, "0",
                       "This journey owns only a synthetic passcode it creates from confirmed Off.")
        var createdPasscode = false
        var removedPasscode = false
        defer {
            if createdPasscode && !removedPasscode {
                let note = XCTAttachment(string: "The isolated test passcode was created but UI removal was not verified. Do not treat this failed lane as clean; explicit UI cleanup is required on its dedicated simulator.")
                note.name = "Protected resume test security cleanup incomplete"
                note.lifetime = .keepAlways
                add(note)
            }
        }
        passcode.tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        app.typeText("1234")
        createdPasscode = true
        if app.buttons["OK"].waitForExistence(timeout: 2) { app.buttons["OK"].tap() }
        waitForValue(passcode, "1")
        // Selecting an unrelated action opts into background concealment while
        // Stats itself needs no prompt. This isolates readiness from credential
        // UI timing, and never starts, stops or pauses an actual VPN.
        for title in ["Open Lava", "Turn protection on or off", "Edit filters", "View Activity", "Change settings"] {
            let flag = app.switches[title]
            XCTAssertTrue(flag.exists)
            XCTAssertEqual(flag.value as? String, "0", "Only Pause protection is selected in this lane.")
        }
        let pause = app.switches["Pause protection"]
        scrollFullyIntoView(app, pause)
        XCTAssertEqual(pause.value as? String, "0")
        pause.tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 2) { enterPasscode(app) }
        waitForValue(pause, "1")
        nativeBack(app).tap()
        let stats = app.buttons["row.Nerd stats"]
        scrollFullyIntoView(app, stats)
        stats.tap()
        let version = app.descendants(matching: .any).matching(identifier: "diagnostic.Version").firstMatch
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            version.exists && version.label.hasPrefix("Version, ")
                && !version.label.contains("Loading") && !version.label.contains("—")
        }, object: version)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed)
        let originalVersion = version.label
        capture(app, "Protected Nerd Stats accepted value before Home")
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
        app.activate()
        let cover = app.descendants(matching: .any).matching(identifier: "lava-privacy-cover").firstMatch
        let statsRouteCover = app.descendants(matching: .any).matching(identifier: "lava-route-privacy-cover").firstMatch
        XCTAssertTrue(cover.exists || statsRouteCover.exists,
                      "The warm protected frame must stay covered while its five-second native read prepares.")
        let started = Date()
        let deadline = started.addingTimeInterval(15)
        var observations: [String] = []
        var coveredSamples = 0
        var observedReady = false
        repeat {
            // One AX snapshot avoids racing a separate cover query against its
            // removal while checking hidden descendants. Retained recording
            // qualifies visible frames; this only samples after activate returns.
            let tree = app.debugDescription
            let elapsed = Date().timeIntervalSince(started)
            if tree.contains("lava-privacy-cover") || tree.contains("lava-route-privacy-cover") {
                coveredSamples += 1
                XCTAssertFalse(tree.contains("diagnostic.Version"),
                               "The erased query's pending rows must remain outside accessibility under the cover.")
                observations.append(String(format: "%.3fs cover present; Version excluded from AX", elapsed))
                if coveredSamples == 1 { capture(app, "Protected Nerd Stats remains covered during delayed refresh") }
            } else {
                XCTAssertTrue(version.exists, "The first exposed diagnostic frame must already have its result.")
                XCTAssertEqual(version.label, originalVersion)
                XCTAssertFalse(version.label.contains("—"))
                XCTAssertFalse(version.label.contains("Loading"))
                observations.append(String(format: "%.3fs cover absent; accepted Version restored", elapsed))
                observedReady = true
                capture(app, "Protected Nerd Stats reveals its accepted fresh value after refresh")
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        let receipt = XCTAttachment(string: observations.joined(separator: "\n"))
        receipt.name = "Protected Nerd Stats cover and query readiness observations"
        receipt.lifetime = .keepAlways
        add(receipt)
        XCTAssertGreaterThan(coveredSamples, 0)
        XCTAssertTrue(observedReady, "The cover must release once the current scoped query has committed.")
        XCTAssertFalse(cover.exists)
        XCTAssertFalse(statsRouteCover.exists)

        // Native-stack sheets are presented above the root route. Their own
        // sibling cover must conceal a delayed replacement share query; a cover
        // still visible behind the UIKit sheet would not qualify this boundary.
        nativeTab(app, "Guard").tap()
        app.buttons["guard.filter"].tap()
        app.buttons["row.Now filtering"].tap()
        let share = app.buttons["Share your filter"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let reveal = app.buttons["Show the QR code"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 20))
        let code = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LF1-")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let originalCode = code.label
        reveal.tap()
        let qr = app.descendants(matching: .any).matching(identifier: "Filter QR code").firstMatch
        XCTAssertTrue(qr.waitForExistence(timeout: 5))
        capture(app, "Protected Share explicitly revealed before Home")
        XCUIDevice.shared.press(.home)
        let shareBackgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [shareBackgrounded], timeout: 10), .completed)
        app.activate()
        let routeCover = app.descendants(matching: .any).matching(identifier: "lava-route-privacy-cover").firstMatch
        XCTAssertTrue(routeCover.exists,
                      "The presented Share sheet must own a cover above its erased body during refresh.")
        let shareStarted = Date()
        let shareDeadline = shareStarted.addingTimeInterval(15)
        var shareObservations: [String] = []
        var shareCoveredSamples = 0
        var shareReady = false
        repeat {
            let tree = app.debugDescription
            let elapsed = Date().timeIntervalSince(shareStarted)
            if tree.contains("lava-route-privacy-cover") {
                shareCoveredSamples += 1
                XCTAssertFalse(tree.contains("LF1-"), "The setup code must remain outside AX under its sheet cover.")
                XCTAssertFalse(tree.contains("Loading filter"), "The pending share body must remain outside AX under its sheet cover.")
                shareObservations.append(String(format: "%.3fs route cover present; sharing body excluded from AX", elapsed))
                if shareCoveredSamples == 1 { capture(app, "Protected Share sheet owns its cover during delayed refresh") }
            } else {
                XCTAssertTrue(code.exists, "The first exposed Share frame must contain its accepted code.")
                XCTAssertEqual(code.label, originalCode)
                XCTAssertTrue(reveal.exists, "Opted-in background privacy must remask the previously revealed QR.")
                XCTAssertFalse(qr.exists)
                XCTAssertFalse(app.staticTexts["Loading filter…"].exists)
                shareObservations.append(String(format: "%.3fs route cover absent; accepted code and remasked QR restored", elapsed))
                shareReady = true
                capture(app, "Protected Share reveals its fresh code with QR remasked after refresh")
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < shareDeadline
        let shareReceipt = XCTAttachment(string: shareObservations.joined(separator: "\n"))
        shareReceipt.name = "Protected native sheet cover and sharing readiness observations"
        shareReceipt.lifetime = .keepAlways
        add(shareReceipt)
        XCTAssertGreaterThan(shareCoveredSamples, 0)
        XCTAssertTrue(shareReady)
        XCTAssertFalse(routeCover.exists)
        fullSheetHeader(app, title: "Share your filter").buttons["Close"].tap()
        nativeTab(app, "Settings").tap()
        nativeBack(app).tap()
        scrollFullyIntoView(app, securityRow)
        securityRow.tap()
        enterPasscode(app) // Security settings always authenticate an existing code.
        scrollFullyIntoView(app, pause)
        XCTAssertEqual(pause.value as? String, "1")
        pause.tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 2) { enterPasscode(app) }
        waitForValue(pause, "0")
        scrollFullyIntoView(app, passcode)
        passcode.tap()
        enterPasscode(app)
        waitForValue(passcode, "0")
        removedPasscode = true
        nativeBack(app).tap()
        nativeTab(app, "Guard").tap()
        // Native tabs retain the last Guard stack: Share was opened from a
        // filter detail. Return through its two existing parents before checking
        // the unchanged Off panel, rather than treating tab selection as a pop.
        nativeBack(app).tap()
        nativeBack(app).tap()
        assertRound8GuardIsOff(app)
        capture(app, "Protected resume qualification removes its synthetic passcode with Guard off")
        #endif
    }

    private struct AcceptedPixelRegion {
        let name: String
        let frame: CGRect
        let png: Data
    }

    private func regionPNG(_ screenshot: XCUIScreenshot, frame: CGRect) -> Data {
        let image = screenshot.image
        let scale = image.scale
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                            width: frame.width * scale, height: frame.height * scale).integral
        guard let crop = image.cgImage?.cropping(to: pixels),
              let png = UIImage(cgImage: crop).pngData() else {
            XCTFail("Could not read the actual rendered region at \(frame).")
            return Data()
        }
        return png
    }

    private func acceptedPixelRegion(_ app: XCUIApplication, element: XCUIElement, name: String,
                                     maximumHeight: CGFloat? = nil, maximumWidth: CGFloat? = nil) -> AcceptedPixelRegion {
        XCTAssertTrue(element.exists, "The pixel baseline must come from an accepted field.")
        var frame = element.frame.intersection(app.frame)
        // Exclude system chrome and the native tab rail. Only the visible
        // accepted field contributes to this comparison, never the clock.
        if app.tabBars.firstMatch.exists {
            frame = frame.intersection(CGRect(x: app.frame.minX, y: app.frame.minY,
                width: app.frame.width, height: app.tabBars.firstMatch.frame.minY - app.frame.minY))
        }
        if let maximumHeight { frame.size.height = min(frame.height, maximumHeight) }
        if let maximumWidth { frame.size.width = min(frame.width, maximumWidth) }
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        let png = regionPNG(app.screenshot(), frame: frame)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name) accepted pixel baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
        return AcceptedPixelRegion(name: name, frame: frame, png: png)
    }

    private func assertSecurityOffResumeRetainsAcceptedValues(_ app: XCUIApplication, page: String, resume: Int,
                                                              acceptedValues: [(XCUIElement, String)],
                                                              acceptedPixels: [AcceptedPixelRegion] = [],
                                                              assertPage: (() -> Void)? = nil) {
        // launch() resets Security only on this isolated simulator. Query
        // journeys use the native five-second fixture; the editor checks an
        // unsaved draft. Neither app loading, any privacy cover nor a cleared
        // accepted value can be accepted as a transient resume state.
        // XCTest samples accessibility after activate() returns; this does not
        // claim frame-by-frame coverage of the system activation animation.
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [foreground], timeout: 2), .completed,
                       "The pixel sample must target the actual foreground application window.")
        let started = Date()
        let end = started.addingTimeInterval(2)
        var observations: [String] = []
        var capturedFirstSample = false
        repeat {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertFalse(app.activityIndicators["Loading Lava"].exists,
                           "Security-off warm resume must not become app loading.")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "lava-privacy-cover").firstMatch.exists,
                           "Security-off warm resume must not mount the React privacy cover.")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "lava-route-privacy-cover").firstMatch.exists,
                           "Security-off warm resume must not mount a native route privacy cover.")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "lavaPrivacyShield").firstMatch.exists,
                           "Security-off warm resume must not mount the native blur.")
            if page != "Guard" {
                // Guard legitimately includes the same brand in its hero. The
                // cover's identifier above distinguishes those shared words.
                XCTAssertFalse(app.staticTexts["Lava Security"].exists,
                               "The opaque cover heading must remain absent.")
            }
            if !acceptedPixels.isEmpty {
                let rendered = app.screenshot()
                for region in acceptedPixels {
                    let current = regionPNG(rendered, frame: region.frame)
                    if current != region.png {
                        let mismatch = XCTAttachment(data: current, uniformTypeIdentifier: "public.png")
                        mismatch.name = "\(region.name) unexpected resume pixels \(resume)"
                        mismatch.lifetime = .keepAlways
                        add(mismatch)
                        let fullFrame = XCTAttachment(screenshot: rendered)
                        fullFrame.name = "\(region.name) complete unexpected resume frame \(resume)"
                        fullFrame.lifetime = .keepAlways
                        add(fullFrame)
                        let geometry = XCTAttachment(string: String(format: "%.3fs %@ frame=%@", elapsed, region.name, String(describing: region.frame)))
                        geometry.name = "\(region.name) pixel comparison geometry"
                        geometry.lifetime = .keepAlways
                        add(geometry)
                    }
                    XCTAssertTrue(current == region.png,
                                  "\(region.name) must keep identical accepted pixels while the foreground query is pending.")
                    observations.append(String(format: "%.3fs %@: accepted pixels identical", elapsed, region.name))
                }
            }
            let accessibilityReady = acceptedValues.allSatisfy { $0.0.exists }
            if accessibilityReady { assertPage?() }
            observations.append(String(format: "%.3fs %@: app loading, root/route covers and native blur absent", elapsed, page))
            for (element, original) in acceptedValues {
                if element.exists {
                    XCTAssertEqual(element.label, original,
                                   "\(page) must retain accepted content while its native refresh is pending.")
                    observations.append(String(format: "%.3fs %@ = %@", elapsed, element.identifier, element.label))
                } else {
                    XCTAssertFalse(acceptedPixels.isEmpty,
                                   "A deliberately hidden AX body still requires direct retained-pixel proof.")
                    observations.append(String(format: "%.3fs %@: AX authority paused; retained pixels checked directly", elapsed, page))
                }
            }
            if !capturedFirstSample {
                capture(app, "\(page) Security off immediate resume \(resume)")
                capturedFirstSample = true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < end
        // A confirmed all-off display can remain painted while input and AX
        // authority wait for the new snapshot. Require authoritative fields to
        // return as well; eventual restoration alone never proves the pixels.
        for (element, original) in acceptedValues {
            XCTAssertTrue(element.waitForExistence(timeout: 3), "\(page) must restore its current accessibility projection.")
            XCTAssertEqual(element.label, original)
        }
        assertPage?()
        let receipt = XCTAttachment(string: observations.joined(separator: "\n"))
        receipt.name = "\(page) retained values during delayed resume \(resume)"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture(app, "\(page) Security off delayed refresh \(resume)")
    }

    func testGuardMascotHoldLocksPageScrollingThroughDrift() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Guard contact qualification requires an isolated simulator.")
        #else
        let app: XCUIApplication
        if ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1" {
            _ = try round8ReadOnlySyntheticSplitMetadata()
            app = try launchRound8ReadOnlyCloseout()
        } else {
            // Guard contact does not require a saved VPN credential. The normal
            // private simulator exercises the same gesture with protection off.
            app = launch()
            assertRound8GuardIsOff(app)
        }
        let mascot = app.descendants(matching: .any).matching(identifier: "guard.mascot").firstMatch
        XCTAssertTrue(mascot.waitForExistence(timeout: 10), app.debugDescription)
        // This RN destination owns a real UIKit bar. Resolve that lazy query
        // before presentation, not the helper's current-existence fallback.
        let picker = app.navigationBars["Lava Guard"]
        mascot.press(forDuration: 0.15)
        XCTAssertFalse(picker.exists, "An early release remains a tap.")
        mascot.press(forDuration: 1.35)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        picker.buttons["Close"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))

        // A held action retains contact even as the finger drifts. Scrolling
        // remains available from the surrounding page after the contact ends.
        let start = mascot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.35, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 15)),
                    withVelocity: .slow, thenHoldForDuration: 1.1)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "A gently drifting hold must open the picker once. " + app.debugDescription)
        capture(app, "Guard gently drifting hold opens one picker")
        picker.buttons["Close"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["Guard"].waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(mascot)
        let initialY = mascot.frame.minY
        let dragStart = mascot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        dragStart.press(forDuration: 0.15, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: -80)), withVelocity: .slow, thenHoldForDuration: 1.1)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Drift must complete the held action instead of scrolling its page.")
        picker.buttons["Close"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))
        XCTAssertEqual(mascot.frame.minY, initialY, accuracy: 2)
        capture(app, "Guard held contact preserves page position")
        nativeTab(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "Settings native landscape root title")
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    func testGuardPickerRetainsVisibleChoicesAcrossSelectionAndIconConfirmation() throws {
        let app = launch(guardPicker: true)
        nativeTab(app, "Settings").tap()
        app.buttons["row.Customization"].tap()
        app.buttons["Choose Lava Guard"].tap()
        let bar = fullSheetHeader(app, title: "Lava Guard")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        assertFullSheetHeaderGeometry(bar, button: bar.buttons["Close"], edge: .leading)
        let options = app.descendants(matching: .any).matching(identifier: "guardian.options").firstMatch
        let original = app.buttons["guardian.option.original"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        waitForSettledFrame(original)
        XCTAssertEqual(original.frame.minY, options.frame.minY, accuracy: 1.5,
                       "The first choice must own its spacing, without outside card padding.")
        capture(app, "Guard choices begin without extra card padding")
        let aquamarine = app.buttons["guardian.option.aquamarine"]
        for _ in 0..<5 where !aquamarine.isHittable { app.swipeUp() }
        // Main fits the spotlight to the active Guard's prose. Its natural
        // height may change, while the options retain their internal geometry.
        app.swipeUp()
        waitForSettledFrame(aquamarine)
        XCTAssertEqual(aquamarine.frame.maxY, options.frame.maxY, accuracy: 1.5,
                       "The last choice must own its spacing, without outside card padding.")
        let match = app.switches["Match app icon to Lava Guard"]
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        for withIcon in [false, true] {
            if withIcon {
                scrollFullyIntoView(app, match, throughGutter: true)
                waitForSettledFrame(match)
                tapNativeSwitch(match)
                let confirmation = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
                XCTAssertTrue(confirmation.waitForExistence(timeout: 10), XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
                capture(app, "System icon confirmation after enabling icon matching")
                confirmation.buttons["OK"].tap()
                XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
            }
            let sequence = withIcon ? ["aquamarine", "kiwiCreme", "aquamarine"]
                : ["emberObsidian", "strawberryObsidian", "kiwiCreme", "aquamarine", "kiwiCreme"]
            for id in sequence {
                let option = app.buttons["guardian.option.\(id)"]
                scrollFullyIntoView(app, option, throughGutter: true)
                XCTAssertTrue(option.isHittable, app.debugDescription)
                waitForSettledFrame(option)
                let position = option.frame
                let optionsPosition = options.frame
                let header = bar.frame
                option.tap()
                if withIcon {
                    let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
                    XCTAssertTrue(alert.waitForExistence(timeout: 10), "The real iOS icon confirmation must appear.")
                    capture(app, "System icon confirmation for \(id)")
                    alert.buttons["OK"].tap()
                    XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
                }
                let selected = NSPredicate(format: "selected == true")
                expectation(for: selected, evaluatedWith: option)
                waitForExpectations(timeout: 10)
                scrollFullyIntoView(app, option, throughGutter: true)
                waitForSettledFrame(option)
                XCTAssertEqual(option.frame.minY - options.frame.minY,
                               position.minY - optionsPosition.minY, accuracy: 1.5,
                               "Changing spotlight prose cannot rearrange the choices within their group.")
                XCTAssertEqual(option.frame.width, position.width, accuracy: 1.5)
                XCTAssertEqual(option.frame.height, position.height, accuracy: 1.5)
                XCTAssertEqual(options.frame.height, optionsPosition.height, accuracy: 1.5)
                XCTAssertEqual(bar.frame.minY, header.minY, accuracy: 1.5)
                XCTAssertEqual(bar.frame.height, header.height, accuracy: 1.5)
                capture(app, "Guard picker returns from selection \(id) icon \(withIcon)")
                if id == "emberObsidian" || id == "strawberryObsidian" {
                    let spotlightTitle = app.staticTexts[option.label].firstMatch
                    XCTAssertTrue(spotlightTitle.exists)
                    scrollFullyIntoView(app, spotlightTitle, throughGutter: true)
                    capture(app, "Native persisted Guard look \(id) in its foreground spotlight")
                }
            }
        }
        for _ in 0..<6 where !original.isHittable { app.swipeDown() }
        app.swipeDown()
        capture(app, "Aquamarine spotlight uses compact insets and continuous outline")
        app.navigationBars.buttons["Close"].tap()
        let guardRow = app.buttons["Choose Lava Guard"]
        XCTAssertTrue(guardRow.waitForExistence(timeout: 10))
        capture(app, "Customization Aquamarine row shares continuous corner outline")
    }

    /// SwiftUI exposes the shared row as a Switch containing the actual UISwitch.
    /// Tap that native accessory; the row's AX center is its explanatory label.
    private func tapNativeSwitch(_ row: XCUIElement) {
        let accessory = row.switches.firstMatch
        let control = accessory.exists ? accessory : row
        XCTAssertTrue(control.exists, row.debugDescription)
        XCTAssertEqual(control.elementType, .switch, "Only the actual native switch may receive this tap.")
        control.tap()
    }

    private func openVPNSetup(_ app: XCUIApplication) {
        let setup = app.descendants(matching: .any).matching(identifier: "vpn.setup-toggle").firstMatch.switches.firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 10), app.debugDescription)
        if setup.value as? String == "0" { tapNativeSwitch(setup) }
        let empty = app.staticTexts["No configurations"].firstMatch
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "vpn.configuration-row")).firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            empty.exists || saved.exists
        }, object: app)], timeout: 10), .completed, "Setup must reveal either the fresh empty store or its saved rows. Each journey qualifies its own fixture.")
    }

    func testSecurityOffWireGuardCommentDraftRetainsAcrossBackground() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("An unsaved synthetic editor draft is qualified only on an isolated simulator.")
        #else
        let app = launch(paidPlan: true)
        assertRound8GuardIsOff(app)
        nativeTab(app, "Settings").tap()
        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn)
        vpn.tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        let setup = app.descendants(matching: .any).matching(identifier: "vpn.setup-toggle").firstMatch.switches.firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let originalSetup = setup.value as? String
        if originalSetup == "0" { setup.tap() }
        let emptyStore = app.staticTexts["No configurations"].firstMatch
        XCTAssertTrue(emptyStore.waitForExistence(timeout: 10),
                      "This journey requires the isolated simulator's confirmed-empty store.")
        scrollFullyIntoView(app, emptyStore)
        let originalMetadata = emptyStore.label
        XCTAssertFalse(app.buttons["vpn.configuration-row"].exists)
        XCTAssertFalse(app.switches["vpn.row-toggle.0"].exists,
                       "The empty store has no routing row to enable.")
        app.navigationBars["VPN chaining"].buttons["Edit"].tap()
        let add = app.buttons["Add configuration"]
        scrollFullyIntoView(app, add)
        XCTAssertTrue(add.wait(for: \.isEnabled, toEqual: true, timeout: 15),
                      "The existing paid-plan fixture must admit adding an unsaved draft.")
        add.tap()
        let editor = app.navigationBars["WireGuard configuration"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        let admitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            input.exists && input.isEnabled
        }, object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [admitted], timeout: 15), .completed,
                       "The existing QA paid-plan fixture must admit the actual editor.")
        func nativeEditorSave() -> XCUIElement? {
            // The underlying React page also has a Save header item. Resolve
            // the native sheet's full-size pinned footer each time, since the
            // underlying page's accessibility authority can pause on resume.
            let actions = app.buttons.matching(NSPredicate(format: "label == %@", "Save"))
                .allElementsBoundByIndex.filter {
                    let frame = $0.frame
                    return frame.minY >= editor.frame.maxY && frame.width >= 44 && frame.height >= 44
                        && app.frame.contains(frame)
                }
            XCTAssertEqual(actions.count, 1, "The actual native editor must expose one pinned Save action.")
            return actions.first
        }
        let emptySave = try XCTUnwrap(nativeEditorSave())
        XCTAssertFalse(emptySave.isEnabled, "An empty native draft cannot be saved.")
        // Name has its own ordinary UIKit responder. Qualify its suspension and
        // explicit re-admission before establishing the separate Content pixel
        // baseline. This checks committed text, not IME marked-text ordering or
        // input during the unobservable background/activation transition.
        let name = app.textFields["Configuration name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        waitForSettledFrame(name)
        name.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: name)], timeout: 10), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        waitForSettledFrame(app.keyboards.firstMatch, requiresHittable: false)
        let acceptedName = "Security-off unsaved Name draft"
        name.typeText(acceptedName)
        XCTAssertEqual(name.value as? String, acceptedName)
        XCUIDevice.shared.press(.home)
        let nameBackgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [nameBackgrounded], timeout: 10), .completed)
        app.activate()
        let nameReadmitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            name.exists && name.isEnabled
        }, object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [nameReadmitted], timeout: 15), .completed,
                       "The current Name owner must regain editing authority after resume.")
        XCTAssertEqual(name.value as? String, acceptedName,
                       "Suspending the Name responder must retain its exact committed buffer.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == false"), object: name)], timeout: 10), .completed,
                       "Name must not restore keyboard focus without a new tap.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10),
                      "Suspending the only focused Name responder must dismiss its keyboard.")
        waitForSettledFrame(name)
        name.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: name)], timeout: 10), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        waitForSettledFrame(app.keyboards.firstMatch, requiresHittable: false)
        let nameSuffix = " after resume"
        let newestName = acceptedName + nameSuffix
        // A center tap restores focus at the tapped character, not at the end.
        // Name has no clear accessory; tap inside its trailing empty space to
        // select the append position before checking the exact newer buffer.
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        name.typeText(nameSuffix)
        XCTAssertEqual(name.value as? String, newestName,
                       "Fresh authorized typing must extend the retained Name without an older callback replacing it.")
        // A comment is deliberately not a parseable configuration. No key, real
        // endpoint, saved profile, tunnel command, or credential write is used.
        let draft = "# Security-off unsaved background qualification"
        input.tap()
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        // Native validation runs when Save is requested. Any nonempty input
        // enables the action; this journey never requests validation or Save.
        XCTAssertTrue(nativeEditorSave()?.isEnabled == true)
        // A native text view's AX frame includes blank insets. Locate actual
        // first-line glyphs in the full-display screenshot instead; a blank
        // crop must never pass as retained draft pixels. The caret is after the
        // complete comment, outside this exact prefix.
        // UIKit updates AX geometry before its keyboard/scroll animation has
        // finished painting. Establish the existing settled-frame precondition
        // and check the same rendered baseline once more before pressing Home.
        waitForSettledFrame(input)
        let prefix = "# Security-off unsaved"
        let pattern = prefix.filter { !$0.isWhitespace }.map {
            NSRegularExpression.escapedPattern(for: String($0))
        }.joined(separator: "\\s*")
        let matcher = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        func recognizesPrefix(_ candidate: VNRecognizedText) -> Range<String.Index>? {
            guard let match = matcher.firstMatch(in: candidate.string,
                range: NSRange(candidate.string.startIndex..<candidate.string.endIndex, in: candidate.string)) else { return nil }
            return Range(match.range, in: candidate.string)
        }
        func textRequest() -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            return request
        }
        let baseline = XCUIScreen.main.screenshot()
        let fullGlyphSource = XCTAttachment(screenshot: baseline)
        fullGlyphSource.name = "WireGuard exact full screenshot used for accepted prefix OCR"
        fullGlyphSource.lifetime = .keepAlways
        self.add(fullGlyphSource)
        XCTAssertEqual(baseline.image.imageOrientation, .up)
        let image = try XCTUnwrap(baseline.image.cgImage)
        let request = textRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        let prefixBounds = try XCTUnwrap(request.results?.compactMap { observation -> CGRect? in
            guard let candidate = observation.topCandidates(1).first,
                  let range = recognizesPrefix(candidate),
                  let rectangle = try? candidate.boundingBox(for: range) else { return nil }
            return rectangle.boundingBox
        }.first, "The synthetic comment prefix must be visibly recognized before Home.")
        let size = baseline.image.size
        let paddedPrefixFrame = CGRect(x: prefixBounds.minX * size.width,
            y: (1 - prefixBounds.maxY) * size.height,
            width: prefixBounds.width * size.width, height: prefixBounds.height * size.height)
            .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(origin: .zero, size: size))
        // The lower OCR padding overlaps the next line's blinking caret. Its
        // five-point strip contains only the caret/blank padding in the matched
        // iOS 26.5 and 27 RGB sources; all actual prefix ink remains above it.
        // Keep the whole prefix, prove
        // it again with cropped OCR, and compare only these actual glyph pixels.
        let glyphFrame = CGRect(x: paddedPrefixFrame.minX, y: paddedPrefixFrame.minY,
            width: paddedPrefixFrame.width, height: paddedPrefixFrame.height - 5)
        XCTAssertGreaterThan(glyphFrame.height, 0)
        let glyphPixels = regionPNG(baseline, frame: glyphFrame)
        let croppedRequest = textRequest()
        try VNImageRequestHandler(data: glyphPixels, orientation: .up, options: [:]).perform([croppedRequest])
        XCTAssertTrue(croppedRequest.results?.contains { observation in
            observation.topCandidates(1).first.map { recognizesPrefix($0) != nil } ?? false
        } == true, "The accepted crop itself must contain the exact synthetic prefix glyphs.")
        let acceptedGlyphs = XCTAttachment(data: glyphPixels, uniformTypeIdentifier: "public.png")
        acceptedGlyphs.name = "WireGuard OCR-confirmed synthetic prefix accepted glyph baseline"
        acceptedGlyphs.lifetime = .keepAlways
        self.add(acceptedGlyphs)
        let glyphGeometry = XCTAttachment(string: "Recognized prefix=\(prefix); full-display image=\(size); glyph frame=\(glyphFrame); native input AX frame=\(input.frame). Caret excluded; full native draft checked independently.")
        glyphGeometry.name = "WireGuard positively identified glyph geometry"
        glyphGeometry.lifetime = .keepAlways
        self.add(glyphGeometry)
        func assertRetainedGlyphs(_ phase: String) {
            let pixels = regionPNG(XCUIScreen.main.screenshot(), frame: glyphFrame)
            let evidence = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            evidence.name = "WireGuard actual synthetic prefix \(phase)"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            XCTAssertTrue(pixels == glyphPixels, "The actual visible synthetic prefix must keep identical glyph pixels \(phase).")
        }
        let inputLabel = input.label
        capture(app, "WireGuard Security off unsaved comment before Home")
        assertRetainedGlyphs("immediately before Home")
        // The shared sampler checks pixels even when AX authority is paused.
        // Give it this same OCR-positive glyph region, and prove its app-window
        // screenshot uses the identical coordinates before entering the lifecycle.
        let acceptedGlyphRegion = AcceptedPixelRegion(name: "WireGuard visible comment prefix",
            frame: glyphFrame, png: glyphPixels)
        XCTAssertTrue(regionPNG(app.screenshot(), frame: glyphFrame) == glyphPixels,
                      "The shared sampler must address the same accepted visible glyph pixels.")
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
        app.activate()
        assertSecurityOffResumeRetainsAcceptedValues(app, page: "WireGuard draft", resume: 1,
            acceptedValues: [(input, inputLabel)], acceptedPixels: [acceptedGlyphRegion]) {
                assertRetainedGlyphs("after resume")
                XCTAssertTrue(editor.exists, "The retained native sheet must remain open.")
                XCTAssertEqual(input.value as? String, draft,
                               "Security-off resume must keep an unsaved native draft.")
                XCTAssertTrue(nativeEditorSave()?.isEnabled == true,
                              "The native nonempty-draft action must retain its admitted state.")
            }
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, newestName,
                       "The later Content resume must preserve the newest authorized Name buffer.")
        editor.buttons["Cancel"].tap()
        let discard = app.alerts["Discard changes?"].buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        let cancelEditing = app.navigationBars["VPN chaining"].buttons["Cancel editing"]
        XCTAssertTrue(cancelEditing.waitForExistence(timeout: 10))
        waitForSettledFrame(cancelEditing)
        cancelEditing.tap()
        XCTAssertTrue(cancelEditing.waitForNonExistence(timeout: 10))
        scrollFullyIntoView(app, emptyStore)
        XCTAssertEqual(emptyStore.label, originalMetadata,
                       "Discard must preserve the confirmed-empty stored metadata.")
        XCTAssertFalse(app.buttons["vpn.configuration-row"].exists)
        XCTAssertFalse(app.switches["vpn.row-toggle.0"].exists)
        if originalSetup == "0" {
            scrollFullyIntoView(app, setup)
            tapNativeSwitch(setup)
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: setup)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        }
        XCTAssertTrue(nativeBack(app).waitForExistence(timeout: 10))
        waitForSettledFrame(nativeBack(app))
        nativeBack(app).tap()
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        capture(app, "WireGuard comment discarded with Guard and chaining off")
        #endif
    }

    func testVPNChainingUsesTheSameLargeTitleAsDNS() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        let dns = app.buttons["connection.dns"]
        scrollFullyIntoView(app, dns); dns.tap()
        let dnsHeader = app.navigationBars["DNS settings"]
        XCTAssertTrue(dnsHeader.waitForExistence(timeout: 10))
        waitForSettledFrame(dnsHeader)
        let expandedHeight = dnsHeader.frame.height
        XCTAssertGreaterThan(expandedHeight, 60, "The sibling baseline must be an expanded large title.")
        capture(app, "DNS standard large title baseline")
        nativeBack(app).tap()
        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn); vpn.tap()
        let vpnHeader = app.navigationBars["VPN chaining"]
        XCTAssertTrue(vpnHeader.waitForExistence(timeout: 10))
        waitForSettledFrame(vpnHeader)
        XCTAssertEqual(vpnHeader.frame.height, expandedHeight, accuracy: 2,
                       "VPN must inherit DNS's ordinary large-title scaffold, not the embedded-native inline override.")
        let vpnScroll = app.scrollViews.firstMatch
        XCTAssertTrue(vpnScroll.waitForExistence(timeout: 10))
        XCTAssertLessThan(vpnScroll.frame.minY, vpnHeader.frame.maxY - 10,
                          "The hosted VPN page must extend beneath its native large-title bar.")
        capture(app, "VPN standard large title matches DNS")
    }

    func testVPNChainingIsAPushedPageWithNativeControls() throws {
        let app = launch(paidPlan: true)
        nativeTab(app, "Settings").tap()
        let row = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, row); row.tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.buttons["Done"].exists)
        let setup = app.switches["I have a WireGuard configuration"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        if setup.value as? String == "0" { setup.tap() }
        let heading = app.staticTexts["WireGuard configuration"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["vpn.chaining-toggle"].exists, "Individual row switches replace the routing row")
        XCTAssertFalse(app.buttons["Add configuration"].exists, "List mutations require page Edit")
        let edit = app.navigationBars.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        XCTAssertTrue(app.navigationBars.buttons["Save"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["vpn.row-toggle.0"].exists)
        let add = app.buttons["Add configuration"]
        if add.exists && add.isEnabled {
            scrollFullyIntoView(app, add); add.tap()
            let sheet = app.navigationBars["WireGuard configuration"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            let save = app.buttons.matching(NSPredicate(format: "label == %@", "Save")).allElementsBoundByIndex.filter {
                $0.frame.minY >= sheet.frame.maxY && $0.frame.width >= 44
            }
            XCTAssertEqual(save.count, 1, "The configuration editor's Save belongs to its pinned footer.")
            XCTAssertFalse(try XCTUnwrap(save.first).isEnabled)
            sheet.buttons["Cancel"].tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        }
        app.navigationBars.buttons["Cancel editing"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Add configuration"].exists)
        XCUIDevice.shared.press(.home)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)], timeout: 10), .completed)
        app.activate()
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Backgrounding must preserve the VPN panel")
        XCTAssertEqual(setup.value as? String, "1")
        nativeBack(app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
    }

    func testRound8InteractiveVPNBackPreservesNativeRows() throws {
        let app = launch(paidPlan: true)
        nativeTab(app, "Settings").tap()
        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn)
        vpn.tap()
        let header = app.navigationBars["VPN chaining"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let setup = app.descendants(matching: .any).matching(identifier: "vpn.setup-toggle").firstMatch.switches.firstMatch
        scrollFullyIntoView(app, setup)
        let originalValue = setup.value as? String
        let originalFrame = setup.frame
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
        for attempt in 1...2 {
            edge.press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.55)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(header.waitForExistence(timeout: 10))
            capture(app, "Round 8 VPN cancelled Back \(attempt) before accessibility geometry check")
            // Retain the SwiftUI row check: the nested UISwitch had correct
            // geometry even when the identified row was one screen offscreen.
            waitForSettledFrame(setup)
            XCTAssertEqual(setup.value as? String, originalValue)
            XCTAssertEqual(setup.frame.minX, originalFrame.minX, accuracy: 1.5)
            XCTAssertEqual(setup.frame.minY, originalFrame.minY, accuracy: 1.5)
            XCTAssertEqual(app.navigationBars.matching(identifier: "VPN chaining").count, 1)
        }
        tapNativeSwitch(setup)
        let changedValue = originalValue == "1" ? "0" : "1"
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in setup.value as? String == changedValue }, object: nil
        )], timeout: 5), .completed)
        tapNativeSwitch(setup)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in setup.value as? String == originalValue }, object: nil
        )], timeout: 5), .completed)
        waitForSettledFrame(setup)
        capture(app, "Round 8 VPN repeated cancelled Back preserves row geometry and working control")
        edge.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.55)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(header.waitForNonExistence(timeout: 10))
        XCTAssertTrue(vpn.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, vpn)
        capture(app, "Round 8 VPN completed interactive Back returns to Settings")
        vpn.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, setup)
        XCTAssertEqual(setup.value as? String, originalValue)
        XCTAssertEqual(setup.frame.minX, originalFrame.minX, accuracy: 1.5)
        capture(app, "Round 8 VPN reentry after completed Back keeps valid row geometry")
    }

    func testRound8ExternalHelperAdoptersWithoutChangingSettings() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        let customization = app.buttons["row.Customization"]
        scrollFullyIntoView(app, customization)
        customization.tap()
        let liveActivity = app.switches["Use Live Activities"]
        XCTAssertTrue(liveActivity.waitForExistence(timeout: 10))
        let liveHelper = app.staticTexts["Shows Lava status on the Lock Screen and Dynamic Island when available."].firstMatch
        scrollFullyIntoView(app, liveHelper)
        XCTAssertGreaterThan(liveHelper.frame.minY, liveActivity.frame.maxY)
        capture(app, "Round 8 Live Activities explanation outside its control group")
        nativeBack(app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        nativeTab(app, "Guard").tap()
        app.buttons["guard.filter"].tap()
        let automation = app.buttons["row.Auto-switch filters"]
        scrollFullyIntoView(app, automation)
        automation.tap()
        XCTAssertTrue(app.navigationBars["Auto-switch filters"].waitForExistence(timeout: 10))
        let shortcuts = app.buttons["Open Shortcuts"]
        scrollFullyIntoView(app, shortcuts)
        capture(app, "Auto-switch Shortcuts action inside instructions panel")
        let systemSettings = app.buttons["Open the Settings app"]
        let systemHelper = app.staticTexts["Opens Lava’s page in the Settings app — tap Back, then Focus."].firstMatch
        scrollFullyIntoView(app, systemHelper)
        XCTAssertGreaterThan(systemHelper.frame.minY, systemSettings.frame.maxY)
        capture(app, "Round 8 Auto-switch destination explanation outside its action")

        nativeTab(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let account = app.buttons["row.Account & Backup"]
        scrollFullyIntoView(app, account)
        account.tap()
        XCTAssertTrue(app.navigationBars["Account & backup"].waitForExistence(timeout: 10))
        let maintenance = app.buttons["row.Backup maintenance"]
        if maintenance.exists {
            scrollFullyIntoView(app, maintenance)
            maintenance.tap()
            let automatic = app.switches["Automatic backup"]
            let helper = app.staticTexts["Lava waits 5 minutes after your last settings change before it tries an automatic upload."].firstMatch
            scrollFullyIntoView(app, helper)
            XCTAssertGreaterThan(helper.frame.minY, automatic.frame.maxY)
            capture(app, "Round 8 automatic backup explanation outside its control")
        } else {
            capture(app, "Round 8 automatic backup tools gated by existing account and backup state")
        }
        // No protection, backup, Live Activity, or external-system action was
        // activated. Authentication and feature availability remain authoritative.
    }

    func testRound8EntitledVPNEditorSavesSyntheticSplitConfigurationWithGuardOff() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic configuration qualification is simulator-only.")
        #else
        guard ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Opt-in lane requires QA identity and a dedicated empty simulator store.")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-LavaQAForcePaidPlan", "YES",
        ]
        // QA authentication remains real; these synthetic fixture lanes never
        // use the DEBUG-only reset hook or the physical qualification lane.
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        XCTAssertTrue(nativeTab(app, "Guard").waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.height > app.frame.width && app.frame.width > 0 },
            object: nil
        )], timeout: 10), .completed)

        assertRound8GuardIsOff(app)
        capture(app, "Entitled editor gate: Guard off before fixture")
        nativeTab(app, "Settings").tap()
        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn)
        vpn.tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        openVPNSetup(app)
        let configuration = app.buttons["vpn.configuration-row"]
        scrollFullyIntoView(app, configuration)
        // Do not overwrite any previous configuration, including an unreadable one.
        guard configuration.label.contains("No configuration"),
              !configuration.label.contains("Saved configuration unavailable") else {
            capture(app, "Entitled editor gate refused: store is not confirmed empty")
            XCTFail("This lane requires a confirmed empty dedicated-simulator configuration store.")
            return
        }
        let chaining = app.switches["vpn.chaining-toggle"]
        XCTAssertTrue(chaining.exists)
        XCTAssertEqual(chaining.value as? String, "0", "The lane never enables chaining.")
        configuration.tap()
        let editor = app.navigationBars["WireGuard configuration"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        // Startup applies the existing entitlement override asynchronously. Wait for
        // actual policy admission; a disabled-editor pass is not this qualification.
        let admitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in input.isEnabled }, object: nil)
        guard XCTWaiter.wait(for: [admitted], timeout: 15) == .completed else {
            capture(app, "Entitled editor gate refused: input remains disabled")
            XCTFail("Existing Plus override and real store eligibility did not admit editing.")
            return
        }
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled)

        // Generated synthetic bytes match the established parser-test convention;
        // no real account, device, or VPN credential is read. Documentation endpoint
        // plus zero keepalive; Guard/chaining remain off throughout this method.
        let privateKey = Data(repeating: 7, count: 32).base64EncodedString()
        let peerKey = Data([
            0xe6, 0xdb, 0x37, 0x1d, 0x9a, 0x2a, 0x1e, 0x2c, 0x4d, 0x5b, 0x6f, 0x71, 0x83, 0x94,
            0xa5, 0xb6, 0xc7, 0xd8, 0xe9, 0xfa, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61, 0x72,
            0x83, 0x94, 0xa5, 0x36,
        ]).base64EncodedString()
        let configurationText = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.64.0.2/32
        DNS = 10.64.0.1

        [Peer]
        PublicKey = \(peerKey)
        Endpoint = 192.0.2.1:51820
        AllowedIPs = 10.64.0.0/24
        PersistentKeepalive = 0
        """
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText(configurationText)
        XCTAssertTrue((input.value as? String ?? "").contains(privateKey))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.isHittable, "The shared footer must keep Save reachable above the keyboard.")
        capture(app, "Entitled editor: synthetic split configuration and keyboard")
        save.tap()
        guard editor.waitForNonExistence(timeout: 15) else {
            capture(app, "Entitled editor gate refused: real Save did not succeed")
            XCTFail("Save must succeed through the existing identity, parser and Keychain boundary.")
            return
        }
        scrollFullyIntoView(app, configuration)
        XCTAssertTrue(configuration.label.contains("Configuration saved"), configuration.label)
        XCTAssertFalse(configuration.label.contains("Saved configuration unavailable"))
        XCTAssertEqual(chaining.value as? String, "0", "Saving credentials must not enable routing.")
        capture(app, "Entitled editor: saved metadata with chaining off")
        configuration.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse((input.value as? String ?? "").contains(privateKey))
        XCTAssertFalse((input.value as? String ?? "").contains("PrivateKey ="))
        XCTAssertFalse(save.isEnabled, "Reopening shows a fresh draft, never stored private-key text.")
        XCTAssertTrue(app.buttons["Delete configuration"].exists)
        capture(app, "Entitled editor: reopened with secret absent")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        nativeBack(app).tap()
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        capture(app, "Entitled editor gate complete: Guard remains off")
        // Leave the clearly synthetic saved fixture in the dedicated simulator for
        // subsequent explicitly selected UI lanes; no file import/start/network here.
        #endif
    }

    func testRound8PaidVPNEditorMaximumDynamicTypeKeepsDraftAndFooterVisible() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Enabled-editor large-text qualification is simulator-only.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchRound8ReadOnlyPaidVPNEditor(maximumTextSize: true)
        let editor = app.navigationBars["WireGuard configuration"]
        let input = app.textViews.firstMatch
        let chooseFile = app.buttons["Choose file"]
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(chooseFile.isEnabled)
        XCTAssertTrue(chooseFile.isHittable)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("# large")
        XCTAssertTrue((input.value as? String ?? "").contains("# large"))
        XCTAssertTrue(input.isHittable)
        let keyboard = app.keyboards.firstMatch
        let window = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.exists && $0.frame.height > $0.frame.width
        })
        let top = max(window.frame.minY, editor.frame.maxY)
        let bottom = min(keyboard.frame.minY, min(chooseFile.frame.minY, save.frame.minY) - 12)
        XCTAssertGreaterThan(bottom, top)
        let band = CGRect(x: window.frame.minX, y: top, width: window.frame.width, height: max(0, bottom - top))
        let exposed = input.frame.intersection(band)
        XCTAssertFalse(exposed.isNull)
        XCTAssertGreaterThanOrEqual(exposed.height, 44, "Maximum text size still needs an exposed editing line above the footer and keyboard.")
        for action in [chooseFile, save] {
            XCTAssertTrue(action.isEnabled)
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            XCTAssertLessThanOrEqual(action.frame.maxY, keyboard.frame.minY)
        }
        capture(app, "Enabled VPN editor at maximum Dynamic Type: portrait draft and both footer actions")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        assertRound8VisibleLandscapeEditing(app, editor: editor, suffix: " LARGEFONT")
        capture(app, "Enabled VPN editor at maximum Dynamic Type: landscape visible draft before footer scrolling")
        let draftBeforeFooterScrolling = try XCTUnwrap(input.value as? String)
        for action in [chooseFile, save] {
            // Compact-height sheet actions follow the content in its scroll;
            // qualify each action's reachability separately from focused text.
            try scrollRound8EditorFooterIntoView(app, editor: editor, action: action,
                                                expectedDraft: draftBeforeFooterScrolling)
            waitForSettledFrame(action)
            XCTAssertTrue(action.isEnabled)
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            XCTAssertLessThanOrEqual(action.frame.maxY, keyboard.frame.minY)
            capture(app, "Enabled VPN editor at maximum Dynamic Type: landscape reachable \(action.label)")
        }
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        #endif
    }

    func testRound8PaidVPNEditorInButtonDragScrollsWithoutActivation() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Shared-action drag qualification is simulator-only.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchRound8ReadOnlyPaidVPNEditor(maximumTextSize: true)
        let editor = app.navigationBars["WireGuard configuration"]
        let input = app.textViews.firstMatch
        let action = app.buttons["Choose file"]
        let marker = "# unsaved in-button drag"
        input.tap()
        app.typeText(marker)
        XCTAssertEqual(input.value as? String, marker)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        XCTAssertEqual(input.value as? String, marker)
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        let draft = try XCTUnwrap(input.value as? String)
        // This prepares the candidate's geometry. A baseline that cannot pass
        // this gutter scroll is not a matched in-button causation control.
        try scrollRound8EditorFooterIntoView(app, editor: editor, action: action,
                                            expectedDraft: draft)
        waitForSettledFrame(action)
        let keyboard = app.keyboards.firstMatch
        let window = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.exists && $0.frame.width > $0.frame.height
        })
        let keyboardBefore = keyboard.frame
        let headerBefore = editor.frame
        let windowBefore = window.frame
        let accessories = app.otherElements.matching(identifier: "SystemInputAssistantView")
            .allElementsBoundByIndex.filter { $0.exists && $0.frame.intersects(windowBefore) }
        let accessoryFramesBefore = accessories.map { $0.frame }
        let top = max(windowBefore.minY, headerBefore.maxY) + 4
        let bottom = min(windowBefore.maxY, keyboardBefore.minY,
                         accessoryFramesBefore.map { $0.minY }.min() ?? keyboardBefore.minY) - 4
        let viewport = CGRect(x: windowBefore.minX, y: top,
                              width: windowBefore.width, height: bottom - top)
        let before = action.frame
        XCTAssertTrue(action.isEnabled && action.isHittable && viewport.contains(before))
        let startPoint = CGPoint(x: before.midX, y: before.minY + before.height * 0.25)
        let endPoint = CGPoint(x: startPoint.x, y: viewport.maxY - 8)
        XCTAssertTrue(before.insetBy(dx: 12, dy: 12).contains(startPoint))
        XCTAssertTrue(viewport.insetBy(dx: 4, dy: 4).contains(startPoint))
        XCTAssertTrue(viewport.insetBy(dx: 4, dy: 4).contains(endPoint))
        XCTAssertGreaterThanOrEqual(endPoint.y - startPoint.y, 32,
                                    "The admitted in-button gesture must have room for a real downward pan.")
        let cleanupNote = XCTAttachment(string: "If this invocation fails before its final Cancel and Guard Off assertions, editor cleanup is unverified. Inspect the isolated simulator before reuse; do not confirm a replacement or reset stored configuration.")
        cleanupNote.name = "Cleanup boundary for single in-button pan"
        cleanupNote.lifetime = .keepAlways
        add(cleanupNote)
        capture(app, "In-button drag: complete enabled action before single measured pan")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: startPoint.x - app.frame.minX,
                                               dy: startPoint.y - app.frame.minY))
        let end = origin.withOffset(CGVector(dx: endPoint.x - app.frame.minX,
                                             dy: endPoint.y - app.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 1.0)
        // Observe after release too: the original failure exposed Files only
        // on a later UI observation. Never retry a gesture that activated it.
        let began = ProcessInfo.processInfo.systemUptime
        var samples: [String] = ["before=\(before), viewport=\(viewport), start=\(startPoint), end=\(endPoint)"]
        var previous = CGRect.null
        var stableSamples = 0
        var retainedEditor = true
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            retainedEditor = editor.exists && input.exists && input.value as? String == draft
                && keyboard.exists && !app.collectionViews["File View"].exists
                && !app.alerts.firstMatch.exists && !app.sheets.firstMatch.exists
                && !app.staticTexts["Replace saved configuration?"].exists
            guard retainedEditor else { return true }
            let frame = action.frame
            samples.append("elapsed=\(ProcessInfo.processInfo.systemUptime - began), action=\(frame)")
            stableSamples = abs(frame.minY - previous.minY) < 0.5 ? stableSamples + 1 : 0
            previous = frame
            return stableSamples >= 3 && ProcessInfo.processInfo.systemUptime - began >= 5
        }, object: nil)
        let result = XCTWaiter.wait(for: [observed], timeout: 30)
        let evidence = XCTAttachment(string: samples.joined(separator: "\n"))
        evidence.name = "Single in-button pan measurements"
        evidence.lifetime = .keepAlways
        add(evidence)
        capture(app, "In-button drag: actual state after release observation")
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(retainedEditor, "A scroll must retain the draft and keyboard without activating an action.")
        XCTAssertEqual(window.frame, windowBefore)
        XCTAssertEqual(editor.frame, headerBefore)
        XCTAssertEqual(keyboard.frame, keyboardBefore)
        XCTAssertEqual(accessories.map { $0.frame }, accessoryFramesBefore)
        let after = action.frame
        XCTAssertEqual(after.width, before.width, accuracy: 0.5)
        XCTAssertEqual(after.height, before.height, accuracy: 0.5)
        XCTAssertGreaterThan(after.minY - before.minY, 4,
                             "The button must move with the scroll; a swallowed drag is not a pass.")
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        #endif
    }

    func testRound8NativeContinueDisabledNoOpAndLocalInvalidCodeError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Native primary-action qualification is simulator-only.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        defer { XCUIDevice.shared.orientation = .portrait }
        // The admitted bundle is QA, where launch()'s DEBUG-only security-reset
        // environment flag has no implementation. No reset action is performed.
        let app = launch()
        assertRound8GuardIsOff(app)
        app.buttons["guard.filter"].tap()
        let importButton = app.navigationBars["Filters"].buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        let enterCode = app.buttons["Enter a code"]
        XCTAssertTrue(enterCode.waitForExistence(timeout: 10))
        enterCode.tap()

        let header = fullSheetHeader(app, title: "Enter a code")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        let localError = app.staticTexts["That doesn’t look like a Lava setup code."]
        let emptyCodeError = app.staticTexts["This code doesn’t contain a Lava filter."]
        let blankDraft = try XCTUnwrap(input.value as? String)
        XCTAssertTrue(blankDraft.isEmpty, "The initial entry must be an empty draft.")
        XCTAssertFalse(continueButton.isEnabled)
        XCTAssertFalse(localError.exists)
        XCTAssertFalse(emptyCodeError.exists)

        func tapVisibleContinueCenter(expectedEnabled: Bool) throws {
            // Disabled buttons may not be AX-hittable. Verify actual visible
            // geometry, then send an ordinary coordinate tap without AX activation.
            var previousFrame = CGRect.null
            var stableSamples = 0
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard header.exists, continueButton.exists,
                      continueButton.isEnabled == expectedEnabled,
                      !app.alerts.firstMatch.exists else { return false }
                let frame = continueButton.frame
                let window = app.frame
                guard frame.width >= 44, frame.height >= 44,
                      !frame.isNull, !frame.isInfinite,
                      window.contains(frame), frame.minY >= header.frame.maxY else { return false }
                var bottom = window.maxY
                for keyboard in app.keyboards.allElementsBoundByIndex
                    where keyboard.exists && keyboard.frame.width > 0 && keyboard.frame.height > 0 {
                    bottom = min(bottom, keyboard.frame.minY)
                }
                for accessory in app.otherElements.matching(identifier: "SystemInputAssistantView").allElementsBoundByIndex
                    where accessory.exists && accessory.frame.width > 0 && accessory.frame.height > 0 {
                    if accessory.frame.intersects(window) { bottom = min(bottom, accessory.frame.minY) }
                }
                guard frame.maxY <= bottom else { return false }
                let unchanged = !previousFrame.isNull
                    && abs(frame.minX - previousFrame.minX) < 0.5
                    && abs(frame.minY - previousFrame.minY) < 0.5
                    && abs(frame.width - previousFrame.width) < 0.5
                    && abs(frame.height - previousFrame.height) < 0.5
                stableSamples = unchanged ? stableSamples + 1 : 0
                previousFrame = frame
                return stableSamples >= 2
            }, object: nil)
            let result = XCTWaiter.wait(for: [settled], timeout: 10)
            guard result == .completed else {
                capture(app, "Continue action has no stable fully exposed tap frame")
                XCTFail("Continue must be fully visible outside the keyboard before its ordinary centered tap.")
                throw NSError(domain: "Round8NativePrimaryAction", code: 1)
            }
            let frame = continueButton.frame
            let window = app.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: frame.midX - window.minX, dy: frame.midY - window.minY)
            ).tap()
        }

        capture(app, "Native Continue disabled with blank setup-code draft")
        try tapVisibleContinueCenter(expectedEnabled: false)
        XCTAssertTrue(header.exists)
        XCTAssertEqual(input.value as? String, blankDraft)
        XCTAssertFalse(continueButton.isEnabled)
        XCTAssertFalse(localError.exists, "A tap on disabled Continue must not invoke parsing.")
        XCTAssertFalse(emptyCodeError.exists)
        XCTAssertFalse(app.staticTexts["Filter imported"].exists)
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        capture(app, "Disabled Continue coordinate tap leaves blank draft unchanged")

        // Plain text with no LF1 prefix, URL, or decodable payload: the real
        // strict parser rejects locally before onDecoded or any import stage.
        let invalidDraft = "round8-invalid-plain-text"
        input.tap()
        input.typeText(invalidDraft)
        XCTAssertEqual(input.value as? String, invalidDraft)
        XCTAssertTrue(continueButton.isEnabled)
        XCTAssertFalse(localError.exists)
        try tapVisibleContinueCenter(expectedEnabled: true)
        XCTAssertTrue(localError.waitForExistence(timeout: 5),
                      "Ordinary enabled Continue must execute its native action and show the exact local parsing error.")
        XCTAssertTrue(header.exists)
        XCTAssertEqual(input.value as? String, invalidDraft)
        XCTAssertTrue(continueButton.isEnabled)
        XCTAssertFalse(emptyCodeError.exists)
        XCTAssertFalse(app.staticTexts["Filter imported"].exists)
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        capture(app, "Native Continue enabled action preserves invalid draft and presents local error")

        header.buttons["Back"].tap()
        XCTAssertTrue(enterCode.waitForExistence(timeout: 10))
        fullSheetHeader(app, title: "Import a filter").buttons["Close"].tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata,
                       "Disabled and local-invalid Continue actions must preserve the saved synthetic VPN envelope.")
        capture(app, "Native primary action control complete: Guard off and metadata unchanged")
        #endif
    }

    func testRound8PaidVPNChooseFileCancellationPreservesDraftAndStoredMetadata() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("System VPN file-picker qualification is simulator-only.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        let app = launchRound8ReadOnlyPaidVPNEditor()
        let editor = app.navigationBars["WireGuard configuration"]
        let input = app.textViews.firstMatch
        let marker = "# unsaved picker cancellation"
        input.tap()
        input.typeText(marker)
        let beforeDraft = try XCTUnwrap(input.value as? String)
        let chooseFile = app.buttons["Choose file"]
        XCTAssertTrue(chooseFile.isEnabled)
        XCTAssertTrue(chooseFile.isHittable)
        chooseFile.tap()
        let browser = app.collectionViews["File View"]
        XCTAssertTrue(browser.waitForExistence(timeout: 30), "Choose File must present the actual system Files browser.")
        capture(app, "VPN Choose File opens actual system browser; no import claimed")
        // Match the existing exporter lane: Files may expose a synthetic Cancel
        // element that is not hittable. Its real sheet also supports pull-down.
        let cancel = app.navigationBars.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.filter { $0.isHittable }
        if cancel.count == 1 {
            cancel[0].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        XCTAssertTrue(browser.waitForNonExistence(timeout: 10))
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, beforeDraft, "Cancelling file selection retains the unsaved editor draft.")
        XCTAssertFalse(app.staticTexts["Can’t save this configuration"].exists, "User cancellation must not create a validation failure.")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        XCTAssertTrue(chooseFile.isEnabled)
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        capture(app, "Cancelled VPN file picker returns to unchanged unsaved draft")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        #endif
    }

    func testRound8PaidVPNImportsPublicFileIntoDraftAndCancelsWithoutSaving() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Public VPN file import qualification requires the isolated QA simulator.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        let filename = "lava-round8-public-synthetic.conf"
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["LAVA_QA_PUBLIC_VPN_IMPORT_PATH"])
        let fixtureURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let expectedPath = "/Users/imjmln/Library/Developer/CoreSimulator/Devices/67BAF9F5-5742-4BCB-8DBF-4400F3035A1C/data/Containers/Shared/AppGroup/E68CC56D-EB73-40FD-A94D-39A12574441A/File Provider Storage/\(filename)"
        guard fixtureURL.path == expectedPath else {
            XCTFail("Import fixture must be the one provisioned public file in the dedicated simulator.")
            return
        }
        let expectedContents = """
        [Interface]
        PrivateKey = BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=
        Address = 10.64.0.2/32
        DNS = 10.64.0.1

        [Peer]
        PublicKey = 5ts3HZoqHixNW29xg5SltsfY6foLHC0+T1BhcoOUpTY=
        Endpoint = 192.0.2.1:51820
        AllowedIPs = 10.64.0.0/24
        PersistentKeepalive = 0
        """ + "\n"
        let fixtureContents = try Data(contentsOf: fixtureURL)
        guard fixtureContents == Data(expectedContents.utf8) else {
            XCTFail("Only the exact public synthetic configuration is admitted to this import lane.")
            throw NSError(domain: "Round8PublicImportFixture", code: 1)
        }
        let app = launchRound8ReadOnlyPaidVPNEditor()
        let editor = app.navigationBars["WireGuard configuration"]
        let input = app.textViews.firstMatch
        XCTAssertEqual(input.value as? String, "")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        app.buttons["Choose file"].tap()
        let browser = app.collectionViews["File View"]
        XCTAssertTrue(browser.waitForExistence(timeout: 30))
        capture(app, "Public VPN import: actual Files browser before exact filename search")

        let search = app.searchFields["Search"].firstMatch
        if !search.exists {
            let browse = app.tabBars.buttons["Browse"]
            if browse.exists && browse.isHittable { browse.tap() }
        }
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText(filename + "\n")
        }
        // Files exposes the result as this exact cell identifier with a filename
        // child and one file icon. The filename label alone did not activate the
        // document in the observed search result; tap its actual icon instead.
        // Search suggestions and existing exported logs cannot match this cell.
        let file = app.collectionViews.cells.matching(identifier: "\(filename), conf")
        let indexed = file.firstMatch.waitForExistence(timeout: 15)
        guard indexed && file.count == 1,
              file.element.staticTexts.matching(identifier: filename).count == 1,
              file.element.images.count == 1,
              file.element.images.element.isHittable else {
            capture(app, "Public VPN import unqualified: exact provisioned file unavailable in Files")
            let receipt = XCTAttachment(string: "The provisioned public file was not uniquely selectable in the actual Files UI; import remains unqualified. No other file selected.\n\(app.debugDescription)")
            receipt.name = "Public VPN import file-provider indexing evidence"
            receipt.lifetime = .keepAlways
            add(receipt)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            XCTAssertTrue(browser.waitForNonExistence(timeout: 10))
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            editor.buttons["Cancel"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
            nativeTab(app, "Guard").tap()
            assertRound8GuardIsOff(app)
            throw XCTSkip("Public VPN file import unqualified: exact fixture is not indexed/selectable in Files; no substitute file used.")
        }
        capture(app, "Public VPN import: exact synthetic configuration result before selection")
        file.element.images.element.tap()
        XCTAssertTrue(browser.waitForNonExistence(timeout: 10))
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedContents), object: input
        )], timeout: 10), .completed, "The actual file reader must put the exact file contents into the editor draft.")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        capture(app, "Public VPN import: exact file contents in unsaved editor, Save enabled")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        let configuration = app.buttons["vpn.configuration-row"]
        scrollFullyIntoView(app, configuration)
        configuration.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "", "Cancelled imported credentials must not remain in a fresh editor.")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        capture(app, "Public VPN import: fresh blank editor after cancelling imported draft")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata)
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        #endif
    }

    func testRound8PaidVPNAndDNSProviderRowsAtUnchangedPortraitScale() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Provider-row comparison requires the isolated synthetic QA simulator.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        let settingsURL = metadataURL.deletingLastPathComponent().appendingPathComponent("app-configuration.json")
        func savedDNSSettings() throws -> Data {
            let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
            XCTAssertEqual(settings["protectionEnabled"] as? Bool, false, "The isolated comparison must keep saved protection off.")
            let keys = ["resolverPresetID", "customResolverAddress", "customResolverSecondaryAddress", "customResolverName",
                        "fallbackToDeviceDNS", "usesEncryptedDeviceDNSFallback", "fallbackResolverPresetID",
                        "fallbackCustomResolverAddress", "fallbackCustomResolverSecondaryAddress", "fallbackCustomResolverName"]
            // Compare all saved DNS preferences without attaching addresses or
            // unrelated configuration data to the rendered evidence receipt.
            return try JSONSerialization.data(withJSONObject: settings.filter { keys.contains($0.key) }, options: [.sortedKeys])
        }
        let beforeDNSSettings = try savedDNSSettings()
        let app = launchRound8ReadOnlyPaidVPNEditor()
        let editor = app.navigationBars["WireGuard configuration"]
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        assertRound8VPNContentAdmitted(app)

        var observations = ["One launch; portrait; existing theme and text preferences unchanged."]
        var needsDNSRestoration = false
        defer {
            if needsDNSRestoration {
                observations.append("INCOMPLETE CLEANUP: original DNS preferences were not verified restored. Stop before another lane; do not count provider captures as a clean qualification.")
            }
            let receipt = XCTAttachment(string: observations.joined(separator: "\n"))
            receipt.name = "VPN and actual DNS provider row comparison geometry"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
        func record(_ element: XCUIElement, name: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 10))
            scrollFullyIntoView(app, element)
            waitForSettledFrame(element)
            XCTAssertTrue(element.isHittable)
            observations.append("\(name): frame=\(element.frame), label=\(element.label), value=\(String(describing: element.value)), selected=\(element.isSelected), enabled=\(element.isEnabled)")
            capture(app, "Same portrait scale: \(name)")
        }
        func finishWithRestoredSettings() throws {
            XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata,
                           "Row comparison must preserve the complete synthetic VPN metadata envelope.")
            XCTAssertTrue(try savedDNSSettings() == beforeDNSSettings, "Every saved DNS preference must match its initial value.")
            nativeTab(app, "Guard").tap()
            assertRound8GuardIsOff(app)
        }
        record(app.switches["vpn.setup-toggle"], name: "VPN setup control")
        record(app.buttons["vpn.configuration-row"], name: "VPN saved configuration row")
        record(app.switches["vpn.chaining-toggle"], name: "VPN chaining control")

        nativeBack(app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings/dns-resolver")!)
        XCTAssertTrue(app.navigationBars["DNS provider"].waitForExistence(timeout: 10))
        assertWindowOrientation(app, landscape: false)
        let deviceDNS = app.switches["Use Device DNS setting"]
        XCTAssertTrue(deviceDNS.waitForExistence(timeout: 10))
        let usesDeviceDNS = try XCTUnwrap(deviceDNS.value as? String)
        XCTAssertTrue(["0", "1"].contains(usesDeviceDNS))
        func restoreDeviceDNS() throws {
            guard app.navigationBars["DNS provider"].exists else {
                throw NSError(domain: "Round8DNSComparisonCleanup", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "DNS page unavailable; stop before another lane."])
            }
            scrollFullyIntoView(app, deviceDNS)
            waitForSettledFrame(deviceDNS)
            if deviceDNS.value as? String == "0" { deviceDNS.tap() }
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", usesDeviceDNS), object: deviceDNS
            )], timeout: 10) == .completed,
                  try savedDNSSettings() == beforeDNSSettings else {
                throw NSError(domain: "Round8DNSComparisonCleanup", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not verify the original DNS preferences; stop before another lane."])
            }
            needsDNSRestoration = false
            observations.append("Restored initial Device DNS value; all ten saved DNS preference fields match their original values.")
        }
        defer {
            if needsDNSRestoration {
                do {
                    try restoreDeviceDNS()
                    try finishWithRestoredSettings()
                } catch {
                    observations.append("INCOMPLETE CLEANUP: temporary Device DNS change could not be verified restored. Stop before another lane. \(error)")
                    XCTFail("DNS comparison cleanup incomplete; inspect the retained receipt before another lane.")
                }
            }
        }
        if usesDeviceDNS == "1" {
            let fallback = app.switches["Fall back to encrypted DNS"]
            XCTAssertTrue(fallback.waitForExistence(timeout: 10))
            let usesFallback = try XCTUnwrap(fallback.value as? String)
            XCTAssertTrue(["0", "1"].contains(usesFallback))
            observations.append("Initial DNS gate: Device DNS=\(usesDeviceDNS), alternative fallback=\(usesFallback).")
            if usesFallback == "0" {
                // Reuse the existing DNS compound-control journey's reversible
                // Device-DNS switch. It exposes the primary provider list without
                // selecting a provider or touching either fallback preference.
                scrollFullyIntoView(app, deviceDNS)
                XCTAssertTrue(deviceDNS.isEnabled)
                needsDNSRestoration = true
                deviceDNS.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "0"), object: deviceDNS
                )], timeout: 10), .completed)
                observations.append("Temporarily disabled Device DNS to reveal actual provider rows; no provider or fallback control activated.")
            }
        } else {
            observations.append("Initial DNS gate: Device DNS=0; provider rows already available, no preference change needed.")
        }
        // Provider identity is the accessibility label; its address metadata is
        // the value. Inspect the actual selection rows without selecting one.
        // Metadata can make a provider taller than a switch: preserve evidence
        // for rendered alignment/accessory review rather than forcing equal height.
        record(app.buttons["Quad9"], name: "DNS Quad9 provider selection row")
        record(app.buttons["Cloudflare 1.1.1.1"], name: "DNS Cloudflare provider selection row")
        if needsDNSRestoration { try restoreDeviceDNS() }
        try finishWithRestoredSettings()
        #endif
    }

    func testRound8NativeRenameDiscardPreservesStoredIdentityWithoutReset() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Closeout is limited to the opted-in dedicated QA simulator.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        defer { XCTAssertEqual(try? Data(contentsOf: metadataURL), beforeMetadata) }
        var app = try launchRound8ReadOnlyCloseout()
        func openLibrary(_ app: XCUIApplication) {
            let filter = app.buttons["guard.filter"]
            scrollFullyIntoView(app, filter)
            filter.tap()
            XCTAssertTrue(app.buttons["row.Switch or manage filters"].waitForExistence(timeout: 10))
            capture(app, "Round8 Filter identity before unsaved rename")
            app.buttons["row.Switch or manage filters"].tap()
            XCTAssertTrue(app.buttons["Core"].waitForExistence(timeout: 10))
            capture(app, "Round8 My Filters list identity sibling unchanged")
            app.navigationBars.buttons["Edit"].tap()
        }
        func openRename(_ app: XCUIApplication) {
            let core = app.buttons["Core"]
            scrollFullyIntoView(app, core)
            core.tap()
            XCTAssertTrue(app.navigationBars["Rename filter"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.textFields["Filter name"].waitForExistence(timeout: 10))
        }
        func replace(_ field: XCUIElement, with value: String) throws {
            let old = try XCTUnwrap(field.value as? String)
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
            XCTAssertEqual(field.value as? String, value)
        }
        func expectDiscard(_ app: XCUIApplication) {
            XCTAssertTrue(app.alerts["Discard changes?"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.alerts.buttons["Cancel"].exists)
            XCTAssertTrue(app.alerts.buttons["Discard"].exists)
        }
        capture(app, "Round8 Guard filter identity before unsaved rename")
        openLibrary(app)
        openRename(app)
        let savedName = try XCTUnwrap(app.textFields["Filter name"].value as? String)
        let savedEmoji = try XCTUnwrap(app.textFields["filter.identity.emoji.input"].value as? String)
        XCTAssertEqual(savedName, "Core")
        XCTAssertFalse(savedEmoji.isEmpty)
        let changedName = savedName + " Round Eight Draft"
        let changedEmoji = savedEmoji == "🌋" ? "🍐" : "🌋"

        // Name-only changes must protect the draft; neither toolbar cancellation
        // nor an attempted sheet dismissal may silently discard it.
        try replace(app.textFields["Filter name"], with: changedName)
        XCTAssertEqual(app.textFields["filter.identity.emoji.input"].value as? String, savedEmoji)
        app.navigationBars["Rename filter"].buttons["Cancel"].tap()
        expectDiscard(app)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(app.textFields["Filter name"].value as? String, changedName)
        for _ in 0..<2 {
            let bar = app.navigationBars["Rename filter"]
            XCTAssertTrue(bar.exists, "An unsaved interactive dismissal must retain this exact editor.")
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            if app.alerts["Discard changes?"].waitForExistence(timeout: 3) { break }
        }
        expectDiscard(app)
        capture(app, "Round8 native rename interactive dirty dismissal confirmation")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(app.textFields["Filter name"].value as? String, changedName)
        app.navigationBars["Rename filter"].buttons["Cancel"].tap()
        expectDiscard(app)
        app.alerts.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Rename filter"].waitForNonExistence(timeout: 10))

        openRename(app)
        XCTAssertEqual(app.textFields["Filter name"].value as? String, savedName)
        XCTAssertEqual(app.textFields["filter.identity.emoji.input"].value as? String, savedEmoji)
        try replace(app.textFields["filter.identity.emoji.input"], with: changedEmoji)
        XCTAssertEqual(app.textFields["Filter name"].value as? String, savedName)
        app.navigationBars["Rename filter"].buttons["Cancel"].tap()
        expectDiscard(app)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(app.textFields["filter.identity.emoji.input"].value as? String, changedEmoji)
        app.navigationBars["Rename filter"].buttons["Cancel"].tap()
        expectDiscard(app)
        app.alerts.buttons["Discard"].tap()
        XCTAssertTrue(app.navigationBars["Rename filter"].waitForNonExistence(timeout: 10))

        openRename(app)
        XCTAssertEqual(app.textFields["Filter name"].value as? String, savedName)
        XCTAssertEqual(app.textFields["filter.identity.emoji.input"].value as? String, savedEmoji)
        try replace(app.textFields["Filter name"], with: changedName)
        try replace(app.textFields["filter.identity.emoji.input"], with: changedEmoji)
        try replace(app.textFields["Filter name"], with: savedName)
        try replace(app.textFields["filter.identity.emoji.input"], with: savedEmoji)
        app.navigationBars["Rename filter"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Rename filter"].waitForNonExistence(timeout: 10), "Reverting both fields must dismiss without a dirty prompt.")
        XCTAssertFalse(app.alerts["Discard changes?"].exists)
        app.terminate()
        app = try launchRound8ReadOnlyCloseout()
        openLibrary(app)
        openRename(app)
        XCTAssertEqual(app.textFields["Filter name"].value as? String, savedName, "Fresh launch must read the unchanged stored name.")
        XCTAssertEqual(app.textFields["filter.identity.emoji.input"].value as? String, savedEmoji, "Fresh launch must read the unchanged stored emoji.")
        app.navigationBars["Rename filter"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Rename filter"].waitForNonExistence(timeout: 10))
        app.navigationBars.buttons["Close edit mode"].tap()
        nativeBack(app).tap()
        XCTAssertTrue(app.buttons["row.Switch or manage filters"].waitForExistence(timeout: 10))
        nativeBack(app).tap()
        assertRound8GuardIsOff(app)
        #endif
    }

    func testRound8ReadOnlyAdvancedDNSAndFeedbackLayoutWithoutReset() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Closeout is limited to the opted-in dedicated QA simulator.")
        #else
        let (metadataURL, beforeMetadata) = try round8ReadOnlySyntheticSplitMetadata()
        defer { XCTAssertEqual(try? Data(contentsOf: metadataURL), beforeMetadata) }
        let app = try launchRound8ReadOnlyCloseout()
        nativeTab(app, "Settings").tap()
        let rows = ["row.Network activity", "row.Nerd stats", "row.Design system", "row.Phone QA"].map { app.buttons[$0] }
        scrollFullyIntoView(app, rows[3])
        for row in rows {
            XCTAssertTrue(row.exists)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        }
        for index in 1..<rows.count { XCTAssertLessThan(rows[index - 1].frame.minY, rows[index].frame.minY) }
        capture(app, "Round8 Advanced rows ordered Network Nerd Design Phone QA")

        let dns = app.buttons["connection.dns"]
        scrollFullyIntoView(app, dns)
        dns.tap()
        XCTAssertTrue(app.otherElements["dns-content"].waitForExistence(timeout: 10))
        let transport = app.segmentedControls["DNS Transport"]
        let providers = app.staticTexts["DNS Providers"].firstMatch
        if transport.exists && providers.exists {
            scrollFullyIntoView(app, transport)
            XCTAssertLessThan(transport.frame.minY, providers.frame.minY)
            capture(app, "Round8 existing DNS transport precedes providers without preference changes")
        } else {
            let limitation = XCTAttachment(string: "Current saved DNS mode hides transport/providers. This read-only lane did not change preferences and does not qualify their order in that state.")
            limitation.name = "Round8 conditional DNS qualification gap"
            limitation.lifetime = .keepAlways
            add(limitation)
            capture(app, "Round8 existing DNS mode conditional control visibility")
        }
        nativeBack(app).tap()
        let feedback = app.buttons["row.Feedback"]
        scrollFullyIntoView(app, feedback)
        feedback.tap()
        let header = fullSheetHeader(app, title: "Feedback")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let steps = ["1. Topic", "2. Details", "3. Review"].map { app.buttons[$0] }
        for step in steps {
            XCTAssertTrue(step.waitForExistence(timeout: 10))
            XCTAssertGreaterThanOrEqual(step.frame.height, 44)
            XCTAssertGreaterThanOrEqual(step.frame.width, 44)
            XCTAssertTrue(app.frame.contains(step.frame), "The complete step target must fit the current viewport.")
        }
        XCTAssertTrue(steps[0].isEnabled)
        XCTAssertFalse(steps[1].isEnabled)
        XCTAssertFalse(steps[2].isEnabled)
        // This full-app route uses native LavaStepNavigation, not RN DetailSteps.
        // An actual tap on the disabled future target must not reveal later fields.
        steps[2].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Choose a topic"].exists)
        XCTAssertFalse(app.buttons["Submit"].exists)
        capture(app, "Round8 native Feedback 44pt future-disabled steps without submission")
        header.buttons["Cancel"].tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 10))
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        #endif
    }

    private func launchRound8ReadOnlyCloseout() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-LavaQAForcePaidPlan", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        assertWindowOrientation(app, landscape: false)
        assertRound8GuardIsOff(app)
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Protection status")).firstMatch
        guard (status.value as? String ?? "").hasPrefix("Protection Off.") else {
            throw NSError(domain: "Round8ReadOnlyCloseout", code: 1)
        }
        return app
    }

    private func round8ReadOnlySyntheticSplitMetadata() throws -> (URL, Data) {
        guard ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1",
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "67BAF9F5-5742-4BCB-8DBF-4400F3035A1C",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Requires the opted-in dedicated QA simulator and its synthetic split record.")
        }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["LAVA_QA_SYNTHETIC_VPN_METADATA_PATH"])
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.contains("/Devices/67BAF9F5-5742-4BCB-8DBF-4400F3035A1C/data/Containers/Shared/AppGroup/"),
              url.lastPathComponent == "chained-upstream.qa.json" else {
            XCTFail("Refusing metadata outside the dedicated simulator's QA record.")
            throw NSError(domain: "Round8ReadOnlyFixture", code: 1)
        }
        let before = try Data(contentsOf: url)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let metadata = try XCTUnwrap(envelope["configuration"] as? [String: Any])
        let peerKey = Data([
            0xe6, 0xdb, 0x37, 0x1d, 0x9a, 0x2a, 0x1e, 0x2c, 0x4d, 0x5b, 0x6f, 0x71, 0x83, 0x94,
            0xa5, 0xb6, 0xc7, 0xd8, 0xe9, 0xfa, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61, 0x72,
            0x83, 0x94, 0xa5, 0x36,
        ]).base64EncodedString()
        let expected: [String: Any] = [
            "endpointHost": "192.0.2.1", "endpointPort": 51820, "peerPublicKey": peerKey,
            "clientAddress": "10.64.0.2", "dnsAddresses": ["10.64.0.1"],
            "persistentKeepaliveSeconds": 0, "allowedIPs": ["10.64.0.0/24"], "routingPolicy": "splitTunnel",
        ]
        guard envelope["schema"] as? Int == 1,
              let generation = (envelope["generation"] as? NSNumber)?.uint64Value, generation != 0,
              NSDictionary(dictionary: metadata).isEqual(to: expected) else {
            XCTFail("Requires the exact public synthetic split metadata and a saved generation.")
            throw NSError(domain: "Round8ReadOnlyFixture", code: 2)
        }
        return (url, before)
    }

    private func launchRound8ReadOnlyPaidVPNEditor(maximumTextSize: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-LavaQAForcePaidPlan", "YES"]
        if maximumTextSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        assertWindowOrientation(app, landscape: false)
        assertRound8GuardIsOff(app)
        nativeTab(app, "Settings").tap()
        if maximumTextSize {
            let customization = app.buttons["row.Customization"]
            scrollFullyIntoView(app, customization)
            customization.tap()
            let systemSize = app.switches["Match system"]
            scrollFullyIntoView(app, systemSize)
            XCTAssertEqual(systemSize.value as? String, "1", "Maximum Dynamic Type requires existing Match System; do not change saved appearance preferences in this lane.")
            nativeBack(app).tap()
            XCTAssertTrue(app.navigationBars["Customization"].waitForNonExistence(timeout: 10))
        }
        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn)
        vpn.tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        assertRound8VPNContentAdmitted(app)
        XCTAssertEqual(app.switches["vpn.setup-toggle"].value as? String, "1", "The existing setup must remain unchanged.")
        let configuration = app.buttons["vpn.configuration-row"]
        scrollFullyIntoView(app, configuration)
        XCTAssertTrue(configuration.label.contains("Configuration saved"))
        XCTAssertFalse(configuration.label.contains("Saved configuration unavailable"))
        configuration.tap()
        XCTAssertTrue(app.navigationBars["WireGuard configuration"].waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isEnabled, "Qualification requires the actual paid editor, not a disabled fixture.")
        return app
    }

    func testRound8PaidSyntheticVPNReauthorizesRetainedAndResumedPage() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic paid-fixture authentication qualification is simulator-only.")
        #else
        guard ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1",
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "67BAF9F5-5742-4BCB-8DBF-4400F3035A1C",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Requires the opted-in dedicated QA simulator and its synthetic split record.")
        }
        let metadataPath = try XCTUnwrap(ProcessInfo.processInfo.environment["LAVA_QA_SYNTHETIC_VPN_METADATA_PATH"])
        let metadataURL = URL(fileURLWithPath: metadataPath).resolvingSymlinksInPath()
        guard metadataURL.path.contains("/Devices/67BAF9F5-5742-4BCB-8DBF-4400F3035A1C/data/Containers/Shared/AppGroup/"),
              metadataURL.lastPathComponent == "chained-upstream.qa.json" else {
            XCTFail("Refusing a metadata path outside the dedicated simulator's QA record.")
            return
        }
        let beforeMetadata = try Data(contentsOf: metadataURL)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeMetadata) as? [String: Any])
        let configurationMetadata = try XCTUnwrap(envelope["configuration"] as? [String: Any])
        let peerKey = Data([
            0xe6, 0xdb, 0x37, 0x1d, 0x9a, 0x2a, 0x1e, 0x2c, 0x4d, 0x5b, 0x6f, 0x71, 0x83, 0x94,
            0xa5, 0xb6, 0xc7, 0xd8, 0xe9, 0xfa, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61, 0x72,
            0x83, 0x94, 0xa5, 0x36,
        ]).base64EncodedString()
        let expected: [String: Any] = [
            "endpointHost": "192.0.2.1", "endpointPort": 51820, "peerPublicKey": peerKey,
            "clientAddress": "10.64.0.2", "dnsAddresses": ["10.64.0.1"],
            "persistentKeepaliveSeconds": 0, "allowedIPs": ["10.64.0.0/24"], "routingPolicy": "splitTunnel",
        ]
        guard envelope["schema"] as? Int == 1,
              let generation = (envelope["generation"] as? NSNumber)?.uint64Value, generation != 0,
              NSDictionary(dictionary: configurationMetadata).isEqual(to: expected) else {
            XCTFail("Authentication qualification requires the exact saved synthetic split fixture.")
            return
        }
        var createdPasscode = false
        var removedPasscode = false
        defer {
            XCUIDevice.shared.orientation = .portrait
            if createdPasscode && !removedPasscode {
                let note = XCTAttachment(string: "This lane created the isolated test passcode but did not verify UI removal. Stop before another lane; explicit guarded UI cleanup is required. VPN metadata was never intentionally changed.")
                note.name = "Test security cleanup incomplete"
                note.lifetime = .keepAlways
                add(note)
            }
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-LavaQAForcePaidPlan", "YES"]
        // QA does not compile the DEBUG reset fixture. Authentication must be
        // created and removed through the real UI; never supply a reset override.
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        assertWindowOrientation(app, landscape: false)
        assertRound8GuardIsOff(app)
        let prompt = app.staticTexts["Enter passcode"]
        let setup = app.switches["vpn.setup-toggle"]
        let chaining = app.switches["vpn.chaining-toggle"]
        let fallback = app.switches["vpn.fallback-toggle"]
        let configuration = app.buttons["vpn.configuration-row"]
        let vpnBar = app.navigationBars["VPN chaining"]
        let securityRow = app.buttons["row.Security"]
        let vpnRow = app.buttons["connection.vpn"]
        let passcode = app.switches["Passcode"]
        func waitForValue(_ element: XCUIElement, _ value: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                element.exists && element.value as? String == value
            }, object: nil)], timeout: 5), .completed)
        }
        func assertMetadataUnchanged() throws {
            XCTAssertEqual(try Data(contentsOf: metadataURL), beforeMetadata,
                           "Authentication and navigation must preserve the entire VPN metadata envelope.")
        }
        func assertPendingMask(_ name: String) throws {
            XCTAssertTrue(prompt.waitForExistence(timeout: 10))
            for control in [setup, chaining, fallback, configuration] {
                XCTAssertFalse(control.exists, "Pending authentication must hide protected native controls from accessibility.")
            }
            try assertMetadataUnchanged()
            capture(app, name)
        }
        func waitForSettingsRoot() {
            XCTAssertTrue(vpnBar.waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars["Security"].waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        }
        func openVPNAndAuthenticate() {
            scrollFullyIntoView(app, vpnRow)
            waitForSettledFrame(vpnRow)
            vpnRow.tap()
            enterPasscode(app)
            XCTAssertTrue(vpnBar.waitForExistence(timeout: 10))
            assertRound8VPNContentAdmitted(app)
        }
        func requestRetainedSettingsFromGuard() {
            // Protected Settings authenticates before native tab selection. The
            // retained VPN page must remain unavailable while Guard is selected.
            nativeTab(app, "Settings").tap()
        }
        func assertGuardRemainsSelected() {
            XCTAssertTrue(nativeTab(app, "Guard").isSelected,
                          "Pending or cancelled Settings-tab authentication must retain Guard selection.")
            XCTAssertFalse(nativeTab(app, "Settings").isSelected)
        }
        func backgroundAndResume() {
            XCUIDevice.shared.press(.home)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: nil)], timeout: 10), .completed)
            app.activate()
        }

        nativeTab(app, "Settings").tap()
        scrollFullyIntoView(app, securityRow)
        securityRow.tap()
        guard passcode.waitForExistence(timeout: 10), passcode.value as? String == "0" else {
            XCTFail("Refusing an existing or unreadable passcode; this lane only owns a code it creates from confirmed Off.")
            return
        }
        passcode.tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        app.typeText("1234")
        createdPasscode = true
        if app.buttons["OK"].waitForExistence(timeout: 2) { app.buttons["OK"].tap() }
        waitForValue(passcode, "1")
        let settingsProtection = app.switches["Change settings"]
        scrollFullyIntoView(app, settingsProtection)
        if settingsProtection.value as? String == "0" { settingsProtection.tap() }
        waitForValue(settingsProtection, "1")
        let appUnlock = app.switches["Open Lava"]
        scrollFullyIntoView(app, appUnlock)
        if appUnlock.value as? String == "1" {
            appUnlock.tap()
            enterPasscode(app)
        }
        waitForValue(appUnlock, "0")
        nativeBack(app).tap()
        waitForSettingsRoot()
        openVPNAndAuthenticate()
        scrollFullyIntoView(app, setup)
        waitForSettledFrame(setup)
        XCTAssertTrue(setup.isHittable)
        XCTAssertEqual(setup.value as? String, "1", "Use the saved setup; the test must not enable it.")
        scrollFullyIntoView(app, chaining)
        let chainBefore = try XCTUnwrap(chaining.value as? String)
        scrollFullyIntoView(app, fallback)
        let fallbackBefore = try XCTUnwrap(fallback.value as? String)
        func assertAcceptedControls(_ name: String) throws {
            assertRound8VPNContentAdmitted(app)
            XCTAssertFalse(prompt.exists)
            scrollFullyIntoView(app, setup)
            waitForSettledFrame(setup)
            XCTAssertTrue(setup.isHittable)
            XCTAssertEqual(setup.value as? String, "1")
            scrollFullyIntoView(app, chaining)
            XCTAssertEqual(chaining.value as? String, chainBefore)
            scrollFullyIntoView(app, fallback)
            XCTAssertEqual(fallback.value as? String, fallbackBefore)
            try assertMetadataUnchanged()
            capture(app, name)
        }
        // A real native action proves the accepted boundary admits interaction.
        // No draft is entered, saved, imported or deleted.
        scrollFullyIntoView(app, configuration)
        configuration.tap()
        let editor = app.navigationBars["WireGuard configuration"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(prompt.exists, "The current settings grant covers its native editor.")
        XCTAssertTrue(app.textViews.firstMatch.isEnabled, "The existing paid fixture must actually admit editing.")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        try assertAcceptedControls("Paid VPN current grant admits native controls")

        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        requestRetainedSettingsFromGuard()
        try assertPendingMask("Paid VPN retained Settings entry: authentication pending, controls closed")
        assertGuardRemainsSelected()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 10))
        assertGuardRemainsSelected()
        assertRound8GuardIsOff(app)
        XCTAssertFalse(setup.exists)
        try assertMetadataUnchanged()
        capture(app, "Cancelled protected Settings entry retains Guard")

        requestRetainedSettingsFromGuard()
        try assertPendingMask("Paid VPN retained Settings entry before accepted authentication")
        assertGuardRemainsSelected()
        enterPasscode(app)
        XCTAssertTrue(vpnBar.waitForExistence(timeout: 10))
        XCTAssertTrue(nativeTab(app, "Settings").isSelected)
        try assertAcceptedControls("Paid VPN retained return accepted current grant")

        backgroundAndResume()
        try assertPendingMask("Paid VPN direct resume: authentication pending, controls closed")
        enterPasscode(app)
        try assertAcceptedControls("Paid VPN direct resume accepted current grant")
        backgroundAndResume()
        try assertPendingMask("Paid VPN second resume before cancellation")
        app.buttons["Cancel"].tap()
        waitForSettingsRoot()
        try assertMetadataUnchanged()

        scrollFullyIntoView(app, securityRow)
        securityRow.tap()
        enterPasscode(app)
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, passcode)
        waitForValue(passcode, "1")
        passcode.tap()
        enterPasscode(app)
        waitForValue(passcode, "0")
        removedPasscode = true
        try assertMetadataUnchanged()
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        capture(app, "Paid VPN authentication complete: test passcode removed, Guard off, metadata unchanged")
        #endif
    }

    func testRound8EntitledVPNPreferencesAndEditorContinueWithGuardOff() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic configuration continuation is simulator-only.")
        #else
        guard ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Opt-in continuation requires the dedicated QA simulator and its synthetic record.")
        }
        // Only public configuration metadata is inspected. The caller supplies
        // the exact dedicated-simulator path; never discover or read credentials.
        let metadataPath = try XCTUnwrap(ProcessInfo.processInfo.environment["LAVA_QA_SYNTHETIC_VPN_METADATA_PATH"])
        let simulatorID = try XCTUnwrap(ProcessInfo.processInfo.environment["SIMULATOR_UDID"])
        let metadataURL = URL(fileURLWithPath: metadataPath).resolvingSymlinksInPath()
        guard simulatorID == "67BAF9F5-5742-4BCB-8DBF-4400F3035A1C",
              metadataURL.path.contains("/Devices/\(simulatorID)/data/Containers/Shared/AppGroup/"),
              metadataURL.lastPathComponent == "chained-upstream.qa.json" else {
            XCTFail("Metadata must belong to this simulator's explicit QA app-group record.")
            return
        }
        let privateKey = Data(repeating: 7, count: 32).base64EncodedString()
        let peerKey = Data([
            0xe6, 0xdb, 0x37, 0x1d, 0x9a, 0x2a, 0x1e, 0x2c, 0x4d, 0x5b, 0x6f, 0x71, 0x83, 0x94,
            0xa5, 0xb6, 0xc7, 0xd8, 0xe9, 0xfa, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61, 0x72,
            0x83, 0x94, 0xa5, 0x36,
        ]).base64EncodedString()
        func syntheticMetadata(split: Bool) throws -> Data {
            let data = try Data(contentsOf: metadataURL)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let configuration = try XCTUnwrap(envelope["configuration"] as? [String: Any])
            let expected: [String: Any] = [
                "endpointHost": "192.0.2.1", "endpointPort": 51820, "peerPublicKey": peerKey,
                "clientAddress": "10.64.0.2", "dnsAddresses": ["10.64.0.1"],
                "persistentKeepaliveSeconds": 0,
                "allowedIPs": [split ? "10.64.0.0/24" : "0.0.0.0/0"],
                "routingPolicy": split ? "splitTunnel" : "fullTunnel",
            ]
            guard envelope["schema"] as? Int == 1,
                  (envelope["generation"] as? NSNumber)?.uint64Value != nil,
                  (envelope["generation"] as? NSNumber)?.uint64Value != 0,
                  NSDictionary(dictionary: configuration).isEqual(to: expected) else {
                XCTFail("Refusing to replace a record that is not the exact synthetic VPN metadata.")
                throw NSError(domain: "Round8SyntheticFixture", code: 1)
            }
            return data
        }
        // Explicit recovery of this lane's interrupted real full-tunnel Save.
        // The same exact synthetic metadata guard remains mandatory; restoration
        // still runs through the editor and its replacement confirmation.
        let resumeFull = ProcessInfo.processInfo.environment["LAVA_QA_RESUME_SYNTHETIC_FULL_TUNNEL"] == "1"
        _ = try syntheticMetadata(split: !resumeFull)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-LavaQAForcePaidPlan", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        assertWindowOrientation(app, landscape: false)
        assertRound8GuardIsOff(app)

        let chaining = app.switches["vpn.chaining-toggle"]
        let fallback = app.switches["vpn.fallback-toggle"]
        let configuration = app.buttons["vpn.configuration-row"]
        let editor = app.navigationBars["WireGuard configuration"]
        let chainCopy = "Send allowed DNS requests through your VPN. Changes reconnect protection when it’s on."
        let fallbackCopy = "Split-tunnel VPNs only. These lookups leave the VPN tunnel and go to your selected DNS providers."
        func openVPN() {
            nativeTab(app, "Settings").tap()
            let row = app.buttons["connection.vpn"]
            scrollFullyIntoView(app, row)
            row.tap()
            XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
            openVPNSetup(app)
        }
        func setSwitch(_ row: XCUIElement, _ enabled: Bool) {
            scrollFullyIntoView(app, row)
            waitForSettledFrame(row)
            XCTAssertTrue(row.isEnabled)
            let value = enabled ? "1" : "0"
            if row.value as? String != value { tapNativeSwitch(row) }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in row.value as? String == value }, object: nil
            )], timeout: 5), .completed)
            waitForSettledFrame(row)
        }
        func captureHelpers(_ name: String) {
            scrollFullyIntoView(app, chaining)
            waitForSettledFrame(chaining)
            XCTAssertTrue(app.staticTexts[chainCopy].exists)
            scrollFullyIntoView(app, app.staticTexts[chainCopy])
            capture(app, "\(name): static chaining explanation")
            scrollFullyIntoView(app, fallback)
            waitForSettledFrame(fallback)
            XCTAssertTrue(app.staticTexts[fallbackCopy].exists)
            scrollFullyIntoView(app, app.staticTexts[fallbackCopy])
            for obsolete in ["Apply after restart", "Not used by this VPN"] {
                XCTAssertFalse(app.staticTexts[obsolete].exists)
            }
            capture(app, "\(name): static fallback explanation")
        }
        func chooseTheme(_ name: String) {
            nativeTab(app, "Settings").tap()
            let customization = app.buttons["row.Customization"]
            scrollFullyIntoView(app, customization)
            customization.tap()
            let theme = app.segmentedControls["Appearance"].buttons[name]
            scrollFullyIntoView(app, theme)
            theme.tap()
            let systemSize = app.switches["Match system"]
            scrollFullyIntoView(app, systemSize)
            if systemSize.value as? String == "0" { tapNativeSwitch(systemSize) }
            XCTAssertEqual(systemSize.value as? String, "1")
            openVPN()
            scrollFullyIntoView(app, app.switches["vpn.setup-toggle"])
            capture(app, "\(name) entitled VPN introduction at system text scale")
        }
        func checkGuardOffAndReturn() {
            nativeTab(app, "Guard").tap()
            assertRound8GuardIsOff(app)
            // A first Settings tap restores its retained native VPN route.
            nativeTab(app, "Settings").tap()
            XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
            assertRound8VPNContentAdmitted(app)
        }
        func keyboardRotationAndCancel(_ name: String, split: Bool) throws {
            let before = try syntheticMetadata(split: split)
            let chainValue = chaining.value as? String
            let fallbackValue = fallback.value as? String
            scrollFullyIntoView(app, configuration)
            configuration.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            let input = app.textViews.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertTrue(input.isEnabled)
            XCTAssertFalse(app.buttons["Save"].isEnabled)
            let marker = "# unsaved \(name) rotation qualification"
            input.tap()
            input.typeText(marker)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Save"].isHittable)
            capture(app, "\(name) entitled editor keyboard portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            assertWindowOrientation(app, landscape: true)
            XCTAssertTrue((input.value as? String ?? "").contains(marker))
            assertRound8VisibleLandscapeEditing(app, editor: editor, suffix: " visible landscape")
            XCTAssertTrue(editor.buttons["Cancel"].isHittable)
            capture(app, "\(name) entitled editor keyboard landscape")
            editor.buttons["Cancel"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
            XCUIDevice.shared.orientation = .portrait
            assertWindowOrientation(app, landscape: false)
            XCTAssertEqual(try syntheticMetadata(split: split), before, "Cancelled editor must leave the entire metadata envelope unchanged.")
            XCTAssertEqual(chaining.value as? String, chainValue)
            XCTAssertEqual(fallback.value as? String, fallbackValue)
            scrollFullyIntoView(app, configuration)
            configuration.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            XCTAssertFalse((input.value as? String ?? "").contains(marker))
            XCTAssertFalse((input.value as? String ?? "").contains(privateKey))
            XCTAssertFalse(app.buttons["Save"].isEnabled)
            editor.buttons["Cancel"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        }
        func replaceSyntheticConfiguration(split: Bool) throws {
            _ = try syntheticMetadata(split: !split)
            scrollFullyIntoView(app, configuration)
            configuration.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            let input = app.textViews.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertTrue(input.isEnabled)
            input.tap()
            input.typeText("""
            [Interface]
            PrivateKey = \(privateKey)
            Address = 10.64.0.2/32
            DNS = 10.64.0.1

            [Peer]
            PublicKey = \(peerKey)
            Endpoint = 192.0.2.1:51820
            AllowedIPs = \(split ? "10.64.0.0/24" : "0.0.0.0/0")
            PersistentKeepalive = 0
            """)
            XCTAssertTrue(app.buttons["Save"].isHittable)
            app.buttons["Save"].tap()
            let confirmation = app.alerts["Replace saved configuration?"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
            capture(app, "Replace synthetic VPN with \(split ? "split" : "full") tunnel confirmation")
            // Revalidate immediately before the only destructive UI action.
            _ = try syntheticMetadata(split: !split)
            confirmation.buttons["Replace"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 15))
            _ = try syntheticMetadata(split: split)
            XCTAssertTrue(configuration.label.contains("Configuration saved"))
            XCTAssertEqual(chaining.value as? String, "1", "Replacement must preserve the separate chaining preference.")
        }

        // The interrupted Light lane explicitly enabled fallback consent before
        // its full-tunnel replacement. Full policy correctly masks that stored
        // consent in the UI; the split restoration below must reveal it again.
        var originalFallback = true
        if resumeFull {
            openVPN()
            setSwitch(chaining, true)
            XCTAssertFalse(fallback.isEnabled)
            XCTAssertEqual(fallback.value as? String, "0")
            checkGuardOffAndReturn()
            captureHelpers("Resumed exact synthetic full tunnel")
        } else {
            nativeTab(app, "Settings").tap()
            chooseTheme("Light")
            // The verified synthetic fixture may remain after an interrupted lane.
            // Establish Off through the real control before comparing both states.
            setSwitch(chaining, false)
            originalFallback = fallback.value as? String == "1"
            captureHelpers("Light split chaining off")
            setSwitch(chaining, true)
            captureHelpers("Light split chaining on")
            setSwitch(chaining, false)
            captureHelpers("Light split chaining off again")
            setSwitch(chaining, true)
            setSwitch(fallback, false)
            captureHelpers("Light split fallback off")
            setSwitch(fallback, true)
            captureHelpers("Light split fallback on")
            checkGuardOffAndReturn()
            try keyboardRotationAndCancel("Light", split: true)
            try replaceSyntheticConfiguration(split: false)
            XCTAssertFalse(fallback.isEnabled)
            XCTAssertEqual(fallback.value as? String, "0")
            captureHelpers("Light full chaining on")
            setSwitch(chaining, false)
            XCTAssertFalse(fallback.isEnabled, "Stored full-tunnel policy disables fallback even while chaining is off.")
            captureHelpers("Light full chaining off")
            setSwitch(chaining, true)
            checkGuardOffAndReturn()
        }
        chooseTheme("Dark")
        XCTAssertFalse(fallback.isEnabled)
        XCTAssertEqual(fallback.value as? String, "0")
        captureHelpers("Dark full chaining on")
        try keyboardRotationAndCancel("Dark", split: false)
        try replaceSyntheticConfiguration(split: true)
        XCTAssertTrue(fallback.isEnabled)
        XCTAssertEqual(fallback.value as? String, "1", "Split restoration must retain the saved fallback consent.")
        captureHelpers("Dark split restores fallback consent")
        setSwitch(chaining, false)
        setSwitch(fallback, originalFallback)
        captureHelpers("Dark split final chaining off")
        _ = try syntheticMetadata(split: true)
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        capture(app, "Entitled continuation complete: Guard off, synthetic split restored")
        #endif
    }

    func testRound8EntitledVPNRotationSeparatesPageSheetAndKeyboard() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic editor rotation probe is simulator-only.")
        #else
        guard ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Rotation probe requires the opted-in dedicated QA simulator.")
        }
        let simulatorID = try XCTUnwrap(ProcessInfo.processInfo.environment["SIMULATOR_UDID"])
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["LAVA_QA_SYNTHETIC_VPN_METADATA_PATH"])
        let metadataURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard simulatorID == "67BAF9F5-5742-4BCB-8DBF-4400F3035A1C",
              metadataURL.path.contains("/Devices/\(simulatorID)/data/Containers/Shared/AppGroup/"),
              metadataURL.lastPathComponent == "chained-upstream.qa.json" else {
            XCTFail("Rotation probe metadata must belong to this dedicated simulator's QA record.")
            return
        }
        let before = try Data(contentsOf: metadataURL)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let configurationMetadata = try XCTUnwrap(envelope["configuration"] as? [String: Any])
        let peerKey = Data([
            0xe6, 0xdb, 0x37, 0x1d, 0x9a, 0x2a, 0x1e, 0x2c, 0x4d, 0x5b, 0x6f, 0x71, 0x83, 0x94,
            0xa5, 0xb6, 0xc7, 0xd8, 0xe9, 0xfa, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50, 0x61, 0x72,
            0x83, 0x94, 0xa5, 0x36,
        ]).base64EncodedString()
        let expected: [String: Any] = [
            "endpointHost": "192.0.2.1", "endpointPort": 51820, "peerPublicKey": peerKey,
            "clientAddress": "10.64.0.2", "dnsAddresses": ["10.64.0.1"],
            "persistentKeepaliveSeconds": 0, "allowedIPs": ["10.64.0.0/24"], "routingPolicy": "splitTunnel",
        ]
        guard envelope["schema"] as? Int == 1,
              NSDictionary(dictionary: configurationMetadata).isEqual(to: expected) else {
            XCTFail("Rotation probe requires the exact known synthetic split metadata.")
            return
        }
        // No preference, saved configuration, or tunnel action occurs in this probe.
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-LavaQAForcePaidPlan", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        assertWindowOrientation(app, landscape: false)
        assertRound8GuardIsOff(app)
        nativeTab(app, "Settings").tap()
        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn)
        vpn.tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["vpn.setup-toggle"].value as? String, "1")
        let chaining = app.switches["vpn.chaining-toggle"]
        XCTAssertTrue(chaining.waitForExistence(timeout: 10))
        let originalChainingValue = chaining.value as? String
        XCTAssertTrue(originalChainingValue == "0" || originalChainingValue == "1")

        capture(app, "Rotation probe 1: native VPN page portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        capture(app, "Rotation probe 1: native VPN page landscape")
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)

        let configuration = app.buttons["vpn.configuration-row"]
        scrollFullyIntoView(app, configuration)
        configuration.tap()
        let editor = app.navigationBars["WireGuard configuration"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isEnabled)
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, "Rotation probe 2: sheet presented in portrait without keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, "Rotation probe 2: sheet landscape without keyboard")
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)

        // A multiline draft exercises the caret at the end of the editor's
        // internal scroll range, not only its first visible line.
        let marker = "# unsaved keyboard rotation probe\n"
            + (1...12).map { "# synthetic draft line \($0)" }.joined(separator: "\n")
            + "\n# tail"
        input.tap()
        input.typeText(marker)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, "Rotation probe 3: sheet portrait with focused keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        XCTAssertTrue((input.value as? String ?? "").contains(marker))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(editor.buttons["Cancel"].isHittable)
        assertRound8VisibleLandscapeEditing(app, editor: editor, suffix: " visible landscape")
        capture(app, "Rotation probe 3: sheet landscape with retained draft and keyboard")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: metadataURL), before, "Cancel must preserve the exact metadata envelope.")
        XCTAssertEqual(chaining.value as? String, originalChainingValue)
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        capture(app, "Rotation probe complete: Guard off and stored fixture unchanged")
        #endif
    }

    func testRound8RemoveInterruptedSyntheticAppPasscodeThroughUI() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Interrupted synthetic app-passcode cleanup is simulator-only.")
        #else
        guard ProcessInfo.processInfo.environment["LAVA_QA_CLEANUP_SYNTHETIC_PASSCODE"] == "1",
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "67BAF9F5-5742-4BCB-8DBF-4400F3035A1C",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Explicit cleanup is only for this lane's known 1234 app passcode.")
        }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["LAVA_QA_SYNTHETIC_VPN_METADATA_PATH"])
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.contains("/Devices/67BAF9F5-5742-4BCB-8DBF-4400F3035A1C/data/Containers/Shared/AppGroup/"),
              url.lastPathComponent == "chained-upstream.qa.json" else {
            XCTFail("Cleanup requires the existing isolated fixture path.")
            return
        }
        let before = try Data(contentsOf: url)
        let app = launch()
        assertRound8GuardIsOff(app)
        nativeTab(app, "Settings").tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 3) { enterPasscode(app) }
        let security = app.buttons["row.Security"]
        scrollFullyIntoView(app, security)
        security.tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 3) { enterPasscode(app) }
        let passcode = app.switches["Passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        XCTAssertEqual(passcode.value as? String, "1", "Only the interrupted test's enabled app passcode is expected.")
        passcode.tap()
        enterPasscode(app)
        XCTAssertEqual(passcode.value as? String, "0")
        XCTAssertEqual(try Data(contentsOf: url), before, "Passcode cleanup must leave the VPN metadata unchanged.")
        nativeTab(app, "Guard").tap()
        assertRound8GuardIsOff(app)
        capture(app, "Interrupted synthetic app passcode removed through UI; Guard off")
        #endif
    }

    func testRound8EntitledVPNRetainedTabReturnWithGuardOff() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Retained-page qualification uses only the isolated QA simulator.")
        #else
        guard ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1",
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "67BAF9F5-5742-4BCB-8DBF-4400F3035A1C",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Requires the opted-in dedicated QA simulator.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenLavaOnboarding", "YES", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-LavaQAForcePaidPlan", "YES"]
        app.launch()
        XCTAssertTrue(app.otherElements["lava.full-app"].waitForExistence(timeout: 30))
        assertRound8GuardIsOff(app)
        nativeTab(app, "Settings").tap()
        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn)
        vpn.tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        assertRound8VPNContentAdmitted(app)
        for cycle in 1...2 {
            nativeTab(app, "Guard").tap()
            assertRound8GuardIsOff(app)
            nativeTab(app, "Settings").tap()
            XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
            assertRound8VPNContentAdmitted(app)
            capture(app, "Retained VPN tab return \(cycle): actual controls admitted")
        }
        #endif
    }

    private func assertRound8VPNContentAdmitted(_ app: XCUIApplication) {
        let admitted = app.switches["vpn.setup-toggle"].waitForExistence(timeout: 15)
        if !admitted {
            capture(app, "Retained VPN route failed to admit controls")
            let detail = XCTAttachment(string: app.debugDescription)
            detail.name = "Retained VPN route admission failure hierarchy"
            detail.lifetime = .keepAlways
            add(detail)
        }
        XCTAssertTrue(admitted, "A retained title alone does not prove the native page resumed.")
    }

    func testRound8SetupCodeEditorLandscapeKeyboardPreservesVisibleDraft() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Shared-sheet qualification uses only the isolated QA simulator.")
        #else
        guard ProcessInfo.processInfo.environment["LAVA_QA_ENTITLED_VPN_EDITOR"] == "1",
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "67BAF9F5-5742-4BCB-8DBF-4400F3035A1C",
              Bundle(for: RNFullAppUITests.self).bundleIdentifier == "com.lavasec.dev.qa.uitests" else {
            throw XCTSkip("Requires the opted-in dedicated QA simulator.")
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        assertRound8GuardIsOff(app)
        app.buttons["guard.filter"].tap()
        let importButton = app.navigationBars["Filters"].buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        app.buttons["Enter a code"].tap()
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let marker = "LF1-unsaved-landscape-probe"
        input.tap()
        input.typeText(marker)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, "Setup-code sibling: focused portrait draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        let header = fullSheetHeader(app, title: "Enter a code")
        XCTAssertTrue((input.value as? String ?? "").contains(marker))
        assertRound8VisibleLandscapeEditing(app, editor: header, suffix: " visible landscape", footerTitle: "Continue")
        // Leave without decoding or applying a setup; this is a disposable draft.
        header.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["Enter a code"].waitForExistence(timeout: 10))
        fullSheetHeader(app, title: "Import a filter").buttons["Close"].tap()
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        importButton.tap()
        app.buttons["Enter a code"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse((input.value as? String ?? "").contains(marker))
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        capture(app, "Setup-code sibling: fresh draft after dismissal")
        fullSheetHeader(app, title: "Enter a code").buttons["Back"].tap()
        fullSheetHeader(app, title: "Import a filter").buttons["Close"].tap()
        #endif
    }

    private func assertRound8VisibleLandscapeEditing(_ app: XCUIApplication, editor: XCUIElement, suffix: String, footerTitle: String = "Save") {
        let input = app.textViews.firstMatch
        let keyboard = app.keyboards.firstMatch
        func exposedEditorGeometry() -> (window: CGRect, band: CGRect)? {
            guard input.exists, keyboard.exists, input.isHittable,
                  let window = app.windows.allElementsBoundByIndex.first(where: {
                      $0.exists && $0.frame.width > $0.frame.height
                  }) else { return nil }
            let top = max(window.frame.minY, editor.frame.maxY)
            var bottom = min(window.frame.maxY, keyboard.frame.minY)
            // A pinned footer can occlude the editor while XCTest still reports
            // its underlying TextView as hittable. Exclude its actual controls
            // and shared top padding, not just the keyboard's key area.
            let save = app.buttons[footerTitle]
            if save.exists, save.isHittable, save.frame.minY < bottom {
                bottom = save.frame.minY - 12
            }
            for scroll in app.scrollViews.allElementsBoundByIndex where scroll.textViews.count > 0 {
                bottom = min(bottom, scroll.frame.maxY)
            }
            guard bottom > top else { return nil }
            let band = CGRect(x: window.frame.minX, y: top, width: window.frame.width, height: bottom - top)
            let exposed = input.frame.intersection(band)
            guard !exposed.isNull, exposed.height >= 44, exposed.width >= 100 else { return nil }
            return (window.frame, exposed)
        }
        let visible = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            exposedEditorGeometry() != nil
        }, object: nil)], timeout: 10)
        capture(app, "Landscape editor visible viewport check")
        let detail = XCTAttachment(string: app.debugDescription)
        detail.name = "Landscape editor clipping and keyboard hierarchy"
        detail.lifetime = .keepAlways
        add(detail)
        XCTAssertEqual(visible, .completed, "The focused draft needs a visible editing area above the keyboard.")
        guard visible == .completed else { return }
        // Type into the existing focus; do not let tapping an offscreen input
        // auto-scroll it into place and conceal a rotation layout failure.
        app.typeText(suffix)
        XCTAssertTrue((input.value as? String ?? "").contains(suffix))
        XCTAssertTrue(keyboard.exists)
        capture(app, "Landscape editor accepts visible text while keyboard stays open")
        // Accessibility can read and edit text behind a keyboard. Recognize the
        // newly entered suffix inside the exposed input, never elsewhere on the
        // screenshot (such as the keyboard's prediction row).
        guard let geometry = exposedEditorGeometry() else {
            XCTFail("The editor lost its visible viewport after typing.")
            return
        }
        let screenshot = XCUIScreen.main.screenshot()
        let pixelEvidence = XCTAttachment(screenshot: screenshot)
        pixelEvidence.name = "Exact screenshot used for editor suffix OCR"
        pixelEvidence.lifetime = .keepAlways
        add(pixelEvidence)
        let data = screenshot.pngRepresentation
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        guard let rawWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            XCTFail("Screenshot dimensions are required to map OCR into the editor viewport.")
            return
        }
        let swapsAxes = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let pixelWidth = CGFloat(swapsAxes ? rawHeight : rawWidth)
        let pixelHeight = CGFloat(swapsAxes ? rawWidth : rawHeight)
        let window = geometry.window
        let scaleX = pixelWidth / window.width
        let scaleY = pixelHeight / window.height
        // XCUIScreen captures the whole display. This phone lane requires an
        // origin-zero, full-display window; never silently scale a smaller or
        // stale portrait window onto a landscape screenshot. Allow pixel rounding.
        guard pixelWidth > pixelHeight, window.width > 0, window.height > 0,
              abs(window.minX) < 0.5, abs(window.minY) < 0.5,
              abs(scaleX - scaleY) <= max(scaleX, scaleY) * 0.01 else {
            XCTFail("Screenshot/window coordinate mapping is ambiguous: pixels \(pixelWidth)x\(pixelHeight), window \(window), EXIF \(rawOrientation).")
            return
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(data: data, orientation: orientation, options: [:]).perform([request])
            let typedValue = input.value as? String ?? ""
            let expected = (typedValue.contains("\n# tail" + suffix) ? "# tail" + suffix : suffix)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // OCR may omit spaces ("# tail" → "#tail"). Match the exact
            // expected token case-insensitively with whitespace-only tolerance,
            // preserving its original String.Index range for Vision's glyph bounds.
            let token = expected.components(separatedBy: .whitespacesAndNewlines).joined()
            guard !token.isEmpty else {
                XCTFail("Visible editing requires a nonempty exact OCR token.")
                return
            }
            let pattern = token.map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s*")
            let matcher = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            var recognized: [(text: String, frame: CGRect)] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                for match in matcher.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                    guard let range = Range(match.range, in: text),
                          let tokenBounds = try candidate.boundingBox(for: range) else { continue }
                    // Check the matched suffix, not unrelated preceding glyphs in
                    // the same OCR line. A line can extend outside the input while
                    // the complete expected suffix is visibly inside it. The #tail
                    // case still matches and bounds its full required prefix+suffix.
                    let box = tokenBounds.boundingBox
                    guard box.width > 0, box.height > 0 else { continue }
                    // Vision reports normalized bounds in the EXIF-oriented image,
                    // bottom-left origin. Keep the existing pixel-to-screen mapping.
                    let frame = CGRect(
                        x: window.minX + box.minX * pixelWidth / scaleX,
                        y: window.minY + (1 - box.maxY) * pixelHeight / scaleY,
                        width: box.width * pixelWidth / scaleX,
                        height: box.height * pixelHeight / scaleY)
                    recognized.append((String(text[range]), frame))
                }
            }
            XCTAssertTrue(recognized.contains {
                geometry.band.contains($0.frame)
            }, "The complete exact typed token must be visible inside the exposed editor band \(geometry.band), not the keyboard or AX value. Expected: \(expected). Matched token bounds: \(recognized)")
        } catch {
            XCTFail("Could not qualify actual rendered draft text: \(error)")
        }
    }

    private func assertRound8GuardIsOff(_ app: XCUIApplication) {
        let status = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Protection status")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(status)
        XCTAssertTrue((status.value as? String ?? "").lowercased().hasPrefix("protection off."),
                      "Qualification requires Guard already off; it must never start or stop the user's tunnel.")
    }

    func testRound8VPNAndEditorRotateInPlaceInBothThemes() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["Light", "Dark"] {
            let app = launch(paidPlan: true)
            nativeTab(app, "Settings").tap()
            let customization = app.buttons["row.Customization"]
            scrollFullyIntoView(app, customization)
            customization.tap()
            let theme = app.segmentedControls["Appearance"].buttons[appearance]
            scrollFullyIntoView(app, theme)
            theme.tap()
            let systemSize = app.switches["Match system"]
            scrollFullyIntoView(app, systemSize)
            if systemSize.value as? String == "0" {
                let accessory = systemSize.switches.firstMatch
                (accessory.exists ? accessory : systemSize).tap()
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in systemSize.value as? String == "1" }, object: nil
            )], timeout: 5), .completed)
            nativeTab(app, "Settings").tap()
            let vpn = app.buttons["connection.vpn"]
            scrollFullyIntoView(app, vpn)
            capture(app, "Round 8 \(appearance) Settings normal-scale peer rows")
            vpn.tap()
            XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
            capture(app, "Round 8 \(appearance) VPN introduction and setup normal scale")
            openVPNSetup(app)
            let empty = app.staticTexts["No configurations"].firstMatch
            XCTAssertTrue(empty.waitForExistence(timeout: 10), "This private simulator must have no saved credentials.")
            scrollFullyIntoView(app, empty)
            let originalLabel = empty.label
            XCUIDevice.shared.orientation = .landscapeLeft
            assertWindowOrientation(app, landscape: true)
            XCTAssertTrue(app.navigationBars["VPN chaining"].exists)
            XCTAssertEqual(empty.label, originalLabel)
            // The floating native tab bar can overlap the row's wide AX
            // background while its left-aligned empty-state text stays visible.
            // This step verifies retained metadata; the editor below has strict
            // exposed-viewport geometry and screenshot OCR qualification.
            waitForSettledFrame(empty, requiresHittable: false)
            capture(app, "Round 8 \(appearance) VPN rotated in place")
            app.navigationBars["VPN chaining"].buttons["Edit"].tap()
            let add = app.buttons["Add configuration"]
            scrollFullyIntoView(app, add)
            XCTAssertTrue(add.wait(for: \.isEnabled, toEqual: true, timeout: 15))
            add.tap()
            let editor = app.navigationBars["WireGuard configuration"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            XCTAssertTrue(editor.buttons["Cancel"].isHittable)
            capture(app, "Round 8 \(appearance) configuration editor landscape")
            XCUIDevice.shared.orientation = .portrait
            assertWindowOrientation(app, landscape: false)
            XCTAssertTrue(editor.exists)
            let input = app.textViews.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            let canEdit = input.isEnabled
            if canEdit {
                input.tap()
                input.typeText("# unsaved rotation qualification")
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                capture(app, "Round 8 \(appearance) configuration draft with keyboard")
            } else {
                XCTAssertFalse(app.buttons["Save"].isEnabled)
                capture(app, "Round 8 \(appearance) configuration editor disabled without entitlement")
            }
            XCUIDevice.shared.orientation = .landscapeLeft
            assertWindowOrientation(app, landscape: true)
            XCTAssertTrue(editor.buttons["Cancel"].isHittable)
            if canEdit {
                XCTAssertTrue((input.value as? String ?? "").contains("unsaved rotation qualification"))
                assertRound8VisibleLandscapeEditing(app, editor: editor, suffix: " visible landscape")
                capture(app, "Round 8 \(appearance) editor keyboard rotated in place")
            } else {
                XCTAssertFalse(input.isEnabled)
                capture(app, "Round 8 \(appearance) disabled editor rotated in place")
            }
            editor.buttons["Cancel"].tap()
            if canEdit {
                let discard = app.alerts["Discard changes?"].buttons["Discard"]
                XCTAssertTrue(discard.waitForExistence(timeout: 10))
                discard.tap()
            }
            XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
            XCUIDevice.shared.orientation = .portrait
            assertWindowOrientation(app, landscape: false)
            scrollFullyIntoView(app, add)
            XCTAssertTrue(add.isEnabled)
            add.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            if canEdit {
                XCTAssertFalse((app.textViews.firstMatch.value as? String ?? "").contains("unsaved rotation qualification"), "Cancelled text must not persist in the editor.")
            }
            editor.buttons["Cancel"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
            app.navigationBars["VPN chaining"].buttons["Cancel editing"].tap()
            scrollFullyIntoView(app, empty)
            XCTAssertEqual(empty.label, originalLabel, "Cancelling both drafts must preserve the confirmed-empty metadata.")
            XCTAssertFalse(app.buttons["vpn.configuration-row"].exists)
            nativeBack(app).tap()
            XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings/dns-resolver")!)
            XCTAssertTrue(app.navigationBars["DNS settings"].waitForExistence(timeout: 10))
            waitForSettledFrame(app.switches["Device DNS"])
            capture(app, "Round 8 \(appearance) DNS introduction and peer rows normal scale")
        }
    }

    func testRound8ExternalHelpersAndVPNAtLargeText() throws {
        func matchSystem(_ app: XCUIApplication, enabled: Bool) -> Bool {
            nativeTab(app, "Settings").tap()
            let customization = app.buttons["row.Customization"]
            scrollFullyIntoView(app, customization)
            customization.tap()
            let toggle = app.switches["Match system"]
            scrollFullyIntoView(app, toggle)
            let original = toggle.value as? String == "1"
            if original != enabled {
                let accessory = toggle.switches.firstMatch
                (accessory.exists ? accessory : toggle).tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in (toggle.value as? String == "1") == enabled }, object: nil
                )], timeout: 5), .completed)
            }
            return original
        }
        let setup = launch()
        let originalMatchSystem = matchSystem(setup, enabled: true)
        defer {
            let restored = launch()
            if !originalMatchSystem { _ = matchSystem(restored, enabled: false) }
        }
        let app = launch(largeText: true, paidPlan: true)
        nativeTab(app, "Settings").tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "connection.phone").firstMatch.exists)
        capture(app, "Round 8 portrait Settings large text actionable connection rows")
        app.buttons["connection.vpn"].tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        openVPNSetup(app)
        let configurations = app.staticTexts["No configurations"].firstMatch
        scrollFullyIntoView(app, configurations)
        XCTAssertTrue(configurations.isHittable, "The fresh fixture has no saved VPN credentials.")
        XCTAssertFalse(app.switches["vpn.chaining-toggle"].exists, "Saved profiles have individual row controls in the accepted native baseline.")
        capture(app, "Round 8 VPN native row and external static explanation large text")
        let fallback = app.descendants(matching: .any).matching(identifier: "vpn.fallback-toggle").firstMatch.switches.firstMatch
        scrollFullyIntoView(app, fallback)
        XCTAssertTrue(fallback.isHittable)
        for obsolete in ["Apply after restart", "Not used by this VPN"] {
            XCTAssertFalse(app.staticTexts[obsolete].exists)
        }
        capture(app, "Round 8 VPN fallback static footer large text")
        // Qualify the enabled editor on this owned, empty Debug fixture too.
        // The separately opted-in installed-QA maximum-text case cannot stand
        // in for a fresh simulator or admit saved user configuration here.
        app.navigationBars["VPN chaining"].buttons["Edit"].tap()
        let addConfiguration = app.buttons["Add configuration"]
        scrollFullyIntoView(app, addConfiguration); addConfiguration.tap()
        let editor = app.navigationBars["WireGuard configuration"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10)); XCTAssertTrue(input.isEnabled)
        waitForSettledFrame(input); input.tap()
        let maximumTextDraft = "# Synthetic maximum text draft; no keys or endpoint"
        input.typeText(maximumTextDraft)
        XCTAssertEqual(input.value as? String, maximumTextDraft)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        capture(app, "Fresh enabled configuration editor maximum text with keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        let editorContent = app.scrollViews.containing(.textView, identifier: "Content").firstMatch
        XCTAssertTrue(editorContent.waitForExistence(timeout: 10))
        for action in [editorContent.buttons["Choose file"].firstMatch, editorContent.buttons["Save"].firstMatch] {
            try scrollRound8EditorFooterIntoView(app, editor: editor, action: action, expectedDraft: maximumTextDraft)
            capture(app, "Fresh maximum-text landscape editor fully visible \(action.label)")
        }
        XCTAssertTrue(editorContent.buttons["Save"].firstMatch.isEnabled, "The native baseline admits a nonempty draft; strict parsing happens only when Save is explicitly activated.")
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        editor.buttons["Cancel"].tap()
        let discardConfiguration = app.alerts["Discard changes?"].buttons["Discard"]
        XCTAssertTrue(discardConfiguration.waitForExistence(timeout: 10)); discardConfiguration.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        app.navigationBars["VPN chaining"].buttons["Cancel editing"].tap()
        XCTAssertTrue(configurations.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["vpn.configuration-row"].exists, "Maximum-text qualification cannot persist its synthetic draft.")
        // Establish the real landscape viewport on the parent page, then verify
        // the same shared native page in that viewport. In-place native rotation
        // is tracked separately; a portrait screenshot is never landscape proof.
        nativeBack(app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let vpnEntry = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpnEntry)
        waitForSettledFrame(vpnEntry)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        app.buttons["connection.vpn"].tap()
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        scrollFullyIntoView(app, fallback)
        capture(app, "Round 8 VPN fallback landscape large text")
        nativeBack(app).tap()
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings/dns-resolver")!)
        XCTAssertTrue(app.navigationBars["DNS settings"].waitForExistence(timeout: 10))
        let device = app.switches["Device DNS"]
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        capture(app, "Round 8 DNS standalone control and external helper large text")
        nativeTab(app, "Settings").tap()
        let privacy = app.buttons["row.Privacy & data"]
        scrollFullyIntoView(app, privacy)
        privacy.tap()
        let export = app.buttons["Export local logs"]
        scrollFullyIntoView(app, export)
        XCTAssertTrue(export.isHittable)
        capture(app, "Round 8 export standalone action and external ZIP explanation large text")
        // The larger Dynamic Type value is a process argument, never a stored
        // accessibility preference. Relaunch with normal arguments to clear it.
        _ = launch()
    }

    func testPlusScrollEndsAtSubscriptionFooter() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Get Lava Plus today"].tap()
        XCTAssertTrue(app.navigationBars["Lava Plus"].waitForExistence(timeout: 10))
        let privacy = app.links["Privacy Policy"]
        for _ in 0..<6 { app.swipeUp() }
        XCTAssertTrue(privacy.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(privacy)
        XCTAssertTrue(privacy.isHittable, "Repeated upward swipes must stop at the subscription footer, not an empty page.")
        XCTAssertGreaterThan(privacy.frame.minY, app.navigationBars["Lava Plus"].frame.maxY)
        XCTAssertLessThan(privacy.frame.maxY, app.tabBars.firstMatch.frame.minY)
        capture(app, "Plus subscription footer at the end of repeated scrolling")
        XCUIDevice.shared.press(.home)
        app.activate()
        app.swipeUp()
        waitForSettledFrame(privacy)
        XCTAssertTrue(privacy.isHittable, "Backgrounding must not add blank scroll space.")
        capture(app, "Plus retains its scroll bounds after backgrounding")
    }

    func testSudokuSafeAreaAndNativeFilterEditingDuringRefresh() throws {
        let app = launch()
        let mascot = app.descendants(matching: .any).matching(identifier: "guard.mascot").firstMatch
        XCTAssertTrue(mascot.waitForExistence(timeout: 10))
        openSudoku(mascot, in: app)
        let rail = sudokuRail(app)
        XCTAssertTrue(rail.waitForExistence(timeout: 20), app.debugDescription)
        let notes = app.buttons["sudoku-notes-toggle"]
        let assist = app.buttons["sudoku-correctness-toggle"]
        let reset = app.buttons["sudoku-reset"], newPuzzle = app.buttons["sudoku-refresh"]
        for control in [notes, assist, reset, newPuzzle] {
            XCTAssertTrue(control.waitForExistence(timeout: 10)); XCTAssertTrue(control.isHittable)
            XCTAssertTrue(rail.frame.contains(control.frame), "Game tools belong to the shared rail.")
        }
        XCTAssertLessThan(notes.frame.midX, assist.frame.midX)
        XCTAssertLessThan(assist.frame.midX, reset.frame.midX)
        XCTAssertLessThan(reset.frame.midX, newPuzzle.frame.midX)
        XCTAssertEqual(newPuzzle.label, "New puzzle")
        notes.tap(); assist.tap()
        XCTAssertEqual(notes.label, "Notes mode on")
        XCTAssertEqual(assist.label, "Puzzle assistance on")
        capture(app, "Round 9 Sudoku shared rail modes")
        notes.tap(); assist.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "sudoku-refresh").count, 1, "Do not duplicate rail tools in the game body.")
        // Begin this private QA puzzle from its real Reset action, preserving its
        // given numbers. This does not introduce a test-only app/game bypass.
        reset.tap(); app.alerts.buttons["Reset"].tap()
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "sudoku-cell-", ": empty")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), app.debugDescription)
        let cellID = cell.identifier
        let chosen = app.buttons[cellID]
        chosen.tap()
        let four = app.buttons["sudoku-digit-4"], five = app.buttons["sudoku-digit-5"], six = app.buttons["sudoku-digit-6"]
        five.tap()
        let eraser = app.buttons["sudoku-eraser"]
        XCTAssertTrue(eraser.waitForExistence(timeout: 5))
        waitForSettledFrame(eraser)
        XCTAssertEqual(eraser.frame.minX, four.frame.minX, accuracy: 1)
        XCTAssertEqual(eraser.frame.maxX, six.frame.maxX, accuracy: 1)
        XCTAssertEqual(eraser.frame.midX, five.frame.midX, accuracy: 1)
        XCTAssertLessThan(eraser.frame.maxY, five.frame.minY, "Erase stays above the digit gesture band.")
        XCTAssertGreaterThanOrEqual(eraser.frame.height, 44)
        capture(app, "Sudoku shared rail tools and eraser spanning four through six")
        eraser.tap(); XCTAssertTrue(chosen.label.hasSuffix(": empty"))
        notes.tap(); XCTAssertEqual(notes.label, "Notes mode on")
        let first = app.buttons["sudoku-digit-1"]
        first.press(forDuration: 0.08, thenDragTo: six)
        XCTAssertTrue(chosen.label.hasSuffix(": notes 6"), "Scrubbing commits the final digit once; it must not leave earlier digits or toggle the last note off.")
        let two = app.buttons["sudoku-digit-2"]
        let outside = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: two.frame.midX, dy: two.frame.minY - 16))
        two.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.08, thenDragTo: outside)
        XCTAssertTrue(chosen.label.hasSuffix(": notes 6"), "A release above the digit band cancels the entry.")
        capture(app, "Sudoku native scrub final entry and outside cancellation")
        reset.tap(); app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(chosen.label.hasSuffix(": notes 6"))
        newPuzzle.tap(); XCTAssertTrue(app.alerts["New puzzle"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(chosen.label.hasSuffix(": notes 6"), "New puzzle cancellation keeps this puzzle and its notes.")
        app.buttons["sudoku-close"].tap()
        app.buttons["guard.filter"].tap()
        app.buttons["row.Now filtering"].tap()
        let edit = app.navigationBars.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), app.debugDescription)
        let refresh = app.navigationBars.buttons["Update now"]
        recordControlBounds(app, ["RN Edit": edit, "RN Refresh": refresh,
                                 "RN system Back": app.navigationBars.buttons["BackButton"]], phase: "Filter viewing toolbar")
        // Refresh republishes native toolbar items. Resolve the current Edit
        // action after that publication instead of tapping a cached coordinate.
        waitForSettledFrame(edit)
        XCTAssertGreaterThan(edit.frame.midX, app.frame.midX, "Edit must be in the trailing toolbar.")
        if refresh.isEnabled { refresh.tap() }
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        waitForSettledFrame(edit)
        XCTAssertTrue(edit.isEnabled)
        recordControlBounds(app, ["Current Edit after refresh": edit], phase: "Filter refresh toolbar settles before Edit")
        edit.tap()
        let cancel = app.navigationBars.buttons["Cancel editing"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["Save"].isEnabled, "An unchanged valid draft can finish editing without a write.")
        capture(app, "Filter remained responsive while refreshing and entering Edit")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        app.navigationBars.buttons["BackButton"].tap()
        let automation = app.buttons["row.Auto-switch filters"]
        XCTAssertTrue(automation.waitForExistence(timeout: 10))
        automation.tap()
        let automationBar = app.navigationBars["Auto-switch filters"]
        XCTAssertTrue(automationBar.waitForExistence(timeout: 10))
        XCTAssertTrue(nativeBack(app).isHittable)
        XCTAssertFalse(automationBar.buttons["Close"].exists)
        XCTAssertTrue(app.staticTexts["Switch filters on a schedule or with a Focus."].exists)
        capture(app, "Auto-switch filters uses an ordinary native pushed page")
    }

    /// The Simulator's public Core Image decoder has separate standalone full
    /// corpus evidence. This explicit target disposition never falls back from
    /// a failed decode; physical-device decoding remains a Vision assertion.
    private func shareCardQrPayloads(in data: Data) throws -> [String?] {
        #if targetEnvironment(simulator)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let image = try XCTUnwrap(CIImage(data: data))
        return detector.features(in: image).map { ($0 as? CIQRCodeFeature)?.messageString }
        #else
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(data: data, options: [:]).perform([request])
        return request.results?.map(\.payloadStringValue) ?? []
        #endif
    }

    func testSharedReactFilterCardImageExportCancelPreservesSavedFilterAndPrivacy() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Use an isolated simulator for the shared-card export/cancel journey.")
        #else
        let app = launch(retainShareCardEvidence: true)
        let filterTile = app.buttons["guard.filter"]
        XCTAssertTrue(filterTile.waitForExistence(timeout: 10), app.debugDescription)
        filterTile.tap()
        let current = app.buttons["row.Now filtering"]
        XCTAssertTrue(current.waitForExistence(timeout: 10), app.debugDescription)
        current.tap()
        let identity = app.staticTexts["filter.identity.name"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10), app.debugDescription)
        let savedName = identity.label
        XCTAssertFalse(savedName.isEmpty)
        let share = app.buttons["Share your filter"]
        XCTAssertTrue(share.wait(for: \.isEnabled, toEqual: true, timeout: 10), app.debugDescription)
        share.tap()

        let shareHeader = fullSheetHeader(app, title: "Share your filter")
        XCTAssertTrue(shareHeader.waitForExistence(timeout: 15), app.debugDescription)
        let reveal = app.buttons["Show the QR code"]
        let visibleQR = app.descendants(matching: .any).matching(identifier: "Filter QR code").firstMatch
        let setupCode = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'LF1-'")).firstMatch
        let export = app.navigationBars.buttons["Share filter card"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(setupCode.waitForExistence(timeout: 20), "Read the actual saved filter's native-generated setup code.")
        let savedCode = setupCode.label
        XCTAssertTrue(savedCode.hasPrefix("LF1-"))
        let expectedCode = XCTAttachment(string: savedCode)
        expectedCode.name = "Shared card independent saved configuration code"
        expectedCode.lifetime = .keepAlways
        add(expectedCode)
        let expectedName = XCTAttachment(string: savedName)
        expectedName.name = "Shared card independent saved filter name"
        expectedName.lifetime = .keepAlways
        add(expectedName)
        XCTAssertFalse(visibleQR.exists, "Entering Share must not reveal the private QR.")

        for phase in ["initial", "after Security-off reentry"] {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: export)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed,
                           "The actual mounted shared RN card must be ready before exporting: \(phase).")
            // Record an inert point between the real heading and disclosure
            // before the system modal hides the underlying sheet's AX elements.
            // RN exposes this exact paragraph on both its parent and child
            // StaticText. Resolve the first matching node and validate its frame.
            let disclosure = app.staticTexts.matching(NSPredicate(format: "label == %@",
                "Your filter is shared as-is. Review your blocklists, blocked domains, and allowed exceptions before sharing. Anyone with the setup code can see them.")).firstMatch
            _ = try XCTUnwrap(disclosure.waitForExistence(timeout: 10) ? disclosure : nil, app.debugDescription)
            let headerFrame = shareHeader.frame, disclosureFrame = disclosure.frame
            let gapPoint = CGPoint(x: headerFrame.midX, y: headerFrame.maxY + 8)
            let outsidePoint = try XCTUnwrap(headerFrame.width > 0 && disclosureFrame.width > 0 && disclosureFrame.height > 0
                && gapPoint.y < disclosureFrame.minY - 4 ? gapPoint : nil,
                "The cancellation point must remain in the inert heading/disclosure gap.")
            export.tap() // Real share.card/capture; opt-in retention only observes this actual chooser's cancellation.
            let systemSheet = app.otherElements["ActivityListView"].firstMatch
            XCTAssertTrue(systemSheet.waitForExistence(timeout: 20), app.debugDescription)
            // These finite image-specific actions were observed in the actual
            // UIImage chooser. Simulator availability differs from Photos-capable devices.
            let imageAction = systemSheet.descendants(matching: .any).matching(NSPredicate(
                format: "label IN %@", ["Save Image", "Assign to Contact", "Create Watch Face"])).firstMatch
            for _ in 0..<4 where !imageAction.exists { systemSheet.swipeUp() }
            XCTAssertTrue(imageAction.waitForExistence(timeout: 10),
                          "The native sheet must offer an observed image-specific activity, not only a text/link item.")
            // Inspect only. Never invoke any image action, a recipient, or another share activity.
            let metadata = systemSheet.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@", "Scan to import my Lava filter")).firstMatch
            XCTAssertTrue(metadata.waitForExistence(timeout: 10), app.debugDescription)
            capture(app, "Actual shared RN filter-card image share sheet — \(phase)")
            let hierarchy = XCTAttachment(string: systemSheet.debugDescription)
            hierarchy.name = "Image-specific system share-sheet hierarchy — \(phase)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            // LPLinkMetadata intentionally keeps the app icon. This screenshot/AX evidence
            // identifies the actual image share activity; it cannot inspect exported card pixels.
            // The observed Simulator UIImage chooser is a popover with no
            // Close button. Use only its actual system dismissal overlay at the
            // validated inert point, never an app Close or an image activity.
            let popovers = app.popovers.containing(.other, identifier: "ActivityListView")
            let popover = try XCTUnwrap(popovers.count == 1 ? popovers.firstMatch : nil,
                "The actual image ActivityListView must belong to one system popover.")
            let windows = app.windows.containing(.other, identifier: "ActivityListView")
            let window = try XCTUnwrap(windows.count == 1 ? windows.firstMatch : nil)
            let dismissRegions = app.otherElements.matching(identifier: "PopoverDismissRegion")
            let dismissRegion = try XCTUnwrap(dismissRegions.count == 1 ? dismissRegions.firstMatch : nil,
                "Require the observed native popover's dismissal overlay.")
            let popoverFrame = popover.frame, dismissFrame = dismissRegion.frame
            _ = try XCTUnwrap(popoverFrame.contains(systemSheet.frame) && window.frame.contains(outsidePoint)
                && dismissFrame.contains(outsidePoint) && !popoverFrame.contains(outsidePoint)
                && outsidePoint.y < popoverFrame.minY - 8 ? outsidePoint : nil,
                "Refuse cancellation unless the real system overlay covers the inert point outside its image popover.")
            dismissRegion.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: outsidePoint.x - dismissFrame.minX, dy: outsidePoint.y - dismissFrame.minY)).tap()
            XCTAssertTrue(systemSheet.waitForNonExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(fullSheetHeader(app, title: "Share your filter").waitForExistence(timeout: 10))
            if phase == "initial" {
                XCTAssertTrue(reveal.waitForExistence(timeout: 10))
                XCTAssertFalse(visibleQR.exists)
            } else {
                XCTAssertTrue(visibleQR.waitForExistence(timeout: 10))
                XCTAssertFalse(reveal.exists, "Security off preserves the explicitly revealed preview after a cancelled chooser.")
            }
            XCTAssertEqual(setupCode.label, savedCode, "Cancelling image export must preserve the saved configuration.")
            XCTAssertFalse(app.staticTexts["Filter unavailable"].exists)
            XCTAssertFalse(app.staticTexts["Unavailable"].exists)
            XCTAssertEqual(app.alerts.count, 0, "A current export must not leave a stale card-token error.")

            if phase == "initial" {
                scrollFullyIntoView(app, reveal)
                reveal.tap()
                XCTAssertTrue(visibleQR.waitForExistence(timeout: 10), app.debugDescription)
                scrollFullyIntoView(app, visibleQR)
                let screenshot = XCUIScreen.main.screenshot()
                let evidence = XCTAttachment(screenshot: screenshot)
                evidence.name = "On-screen saved-filter preview QR decode (not exported card pixels)"
                evidence.lifetime = .keepAlways
                add(evidence)
                XCTAssertEqual(try shareCardQrPayloads(in: screenshot.pngRepresentation),
                               ["https://lavasecurity.app/app/import/#" + savedCode],
                               "The explicitly revealed preview carries the whole real setup code in its fragment.")
                XCUIDevice.shared.press(.home)
                let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    app.state == .runningBackground || app.state == .runningBackgroundSuspended
                }, object: app)
                XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
                app.activate()
                XCTAssertTrue(visibleQR.waitForExistence(timeout: 10), "The native-confirmed Security-off choice preserves the revealed QR.")
                XCTAssertTrue(reveal.waitForNonExistence(timeout: 10))
                XCTAssertEqual(setupCode.label, savedCode)
                // Preview display retention grants no export authority. The native
                // foreground boundary retires the prior token; the next iteration
                // must remount a fresh ready surface and reach a real image chooser.
                capture(app, "Shared filter Security-off reentry preserves code and revealed preview QR")
            }
        }
        shareHeader.buttons["Close"].tap()
        XCTAssertTrue(shareHeader.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(identity.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(identity.label, savedName)
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.buttons["Cancel editing"].exists, "Sharing must never enter or commit an edit.")
        XCTAssertTrue(share.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        share.tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 15))
        XCTAssertFalse(visibleQR.exists, "Opening the saved filter's share screen again starts concealed.")
        XCTAssertTrue(setupCode.waitForExistence(timeout: 15))
        XCTAssertEqual(setupCode.label, savedCode)
        capture(app, "Saved filter share reopens unchanged after two actual image-export cancellations")
        shareHeader.buttons["Close"].tap()
        XCTAssertTrue(shareHeader.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        XCTAssertEqual(identity.label, savedName)
        #endif
    }

    func testShareResumeAndDirectSystemExport() throws {
        let app = launch(delayedQueries: true)
        app.buttons["guard.filter"].tap()
        app.buttons["row.Now filtering"].tap()
        let share = app.buttons["Share your filter"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(share.isEnabled)
        share.tap()
        let reveal = app.buttons["Show the QR code"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 20), app.debugDescription)
        let shareHeader = fullSheetHeader(app, title: "Share your filter")
        assertFullSheetHeaderGeometry(shareHeader, button: shareHeader.buttons["Close"], edge: .trailing)
        let qrRegion = app.descendants(matching: .any).matching(identifier: "share-qr-region").firstMatch
        XCTAssertTrue(qrRegion.waitForExistence(timeout: 5), app.debugDescription)
        waitForSettledFrame(qrRegion)
        let concealedFrame = qrRegion.frame
        capture(app, "Share QR single concealed pane")
        reveal.tap()
        let qr = app.descendants(matching: .any).matching(identifier: "Filter QR code").firstMatch
        XCTAssertTrue(qr.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(reveal.waitForNonExistence(timeout: 5), app.debugDescription)
        let code = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LF1-")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), app.debugDescription)
        let originalCode = code.label
        waitForSettledFrame(qrRegion)
        XCTAssertEqual(qrRegion.frame.height, concealedFrame.height, accuracy: 1.5)
        XCTAssertEqual(qrRegion.frame.minY, concealedFrame.minY, accuracy: 1.5)
        capture(app, "Share QR explicitly revealed")
        let originalQRLabel = qr.label
        let copy = app.buttons["Copy setup code"]
        scrollFullyIntoView(app, copy)
        copy.tap()
        let copied = app.buttons["Copied"]
        XCTAssertTrue(copied.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, qrRegion)
        let sharePixels = acceptedPixelRegion(app, element: qrRegion, name: "Share accepted revealed QR")
        XCUIDevice.shared.press(.home)
        // Require a completed background transition before checking resume;
        // report a stalled Home transition separately from an activation failure.
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed,
                       "Share must enter the background promptly before testing its opted-out resume.")
        app.activate()
        assertSecurityOffResumeRetainsAcceptedValues(app, page: "Share", resume: 1,
            acceptedValues: [(qr, originalQRLabel), (copied, "Copied")], acceptedPixels: [sharePixels]) {
                XCTAssertFalse(reveal.exists,
                               "Security-off resume must preserve a QR the user already chose to reveal.")
                XCTAssertTrue(code.exists)
                XCTAssertEqual(code.label, originalCode,
                               "Security-off resume must preserve the already-painted setup code.")
            }
        XCTAssertFalse(app.staticTexts["Unavailable"].exists)
        XCTAssertFalse(app.staticTexts["Filter unavailable"].exists)
        XCTAssertFalse(app.staticTexts["Loading filter…"].exists)
        waitForSettledFrame(qrRegion)
        XCTAssertEqual(qrRegion.frame.height, concealedFrame.height, accuracy: 1.5)
        XCTAssertEqual(qrRegion.frame.minY, concealedFrame.minY, accuracy: 1.5)
        fullSheetHeader(app, title: "Share your filter").buttons["Close"].tap()
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings")!)
        let privacy = app.buttons["row.Privacy & data"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        for _ in 0..<4 where !privacy.isHittable { app.swipeUp() }
        privacy.tap()
        XCTAssertFalse(app.switches["Include domain history in this export"].exists)
        let export = app.buttons["Export local logs"]
        for _ in 0..<4 where !export.isHittable { app.swipeUp() }
        export.tap()
        // The system share sheet exports only the ZIP; the disclosure stays on Privacy.
        // XCUITest sees the standard activity list, with no File View collection view.
        let shareSheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 30), "The system share sheet must be present.")
        capture(app, "System share sheet presented for the local-log export")
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 5) {
            close.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: 15), app.debugDescription)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: export)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed, "Dismissing the share sheet must return directly to Privacy and release the export gate.")
        capture(app, "Privacy restored directly after the export share sheet")
    }

    func testTabReselectionPreservesGuardAndReturnsSettingsToCompactTop() throws {
        let app = launch()
        let activity = app.buttons["guard.today"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        let initial = activity.frame
        for _ in 0..<4 {
            nativeTab(app, "Guard").tap()
            XCTAssertEqual(activity.frame.minY, initial.minY, accuracy: 1)
        }
        capture(app, "Guard after four repeated tab taps")
        let guardTabBarFrame = app.tabBars.firstMatch.frame
        nativeTab(app, "Settings").tap()
        let account = app.buttons["row.Account & Backup"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(account)
        XCTAssertEqual(app.tabBars.firstMatch.frame.minY, guardTabBarFrame.minY, accuracy: 1, "Switching to Settings must retain the native tab bar position.")
        let expanded = account.frame
        for _ in 0..<3 {
            nativeTab(app, "Settings").tap()
            XCTAssertEqual(account.frame.minY, expanded.minY, accuracy: 1)
        }
        app.swipeUp()
        nativeTab(app, "Settings").tap()
        waitForSettledFrame(account)
        XCTAssertTrue(account.isHittable)
        XCTAssertGreaterThanOrEqual(account.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1)
        let compact = account.frame
        for _ in 0..<3 {
            nativeTab(app, "Settings").tap()
            XCTAssertEqual(account.frame.minY, compact.minY, accuracy: 1)
        }
        capture(app, "Settings compact title and first row after reselection")
        // XCUIApplication.open launches the app with the URL. System.open
        // delivers the link to the running process so this tests stack retention.
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://guard")!)
        XCTAssertTrue(activity.waitForExistence(timeout: 10), "A native Guard request must work even when its stored SwiftUI tab value was already Guard.")
        XCTAssertTrue(nativeTab(app, "Guard").isSelected)
        activity.tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings/dns-resolver")!)
        let dns = app.navigationBars["DNS settings"]
        XCTAssertTrue(dns.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: nativeTab(app, "Settings"))], timeout: 5), .completed)
        waitForSettledFrame(dns)
        nativeTab(app, "Guard").tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: nativeTab(app, "Guard"))], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10), "A Settings redirect must retain the inactive Guard stack.")
        let retainedActivity = app.navigationBars["Activity"]
        waitForSettledFrame(retainedActivity)
        nativeTab(app, "Guard").tap()
        XCTAssertTrue(activity.waitForExistence(timeout: 10), "Reselecting Guard must pop its Activity page to root.")
        XCTAssertFalse(retainedActivity.exists)
        nativeTab(app, "Settings").tap()
        XCTAssertTrue(dns.waitForExistence(timeout: 10), "Switching tabs retains the other tab's nested page.")
        nativeTab(app, "Settings").tap()
        XCTAssertTrue(account.waitForExistence(timeout: 10), "Reselecting Settings must pop its DNS page to root.")
        XCTAssertFalse(dns.exists)
        capture(app, "Both native tabs return their nested stacks to root")
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings")!)
        let feedbackRow = app.buttons["row.Feedback"]
        scrollFullyIntoView(app, feedbackRow)
        XCTAssertTrue(feedbackRow.isHittable, app.debugDescription)
        feedbackRow.tap()
        let feedback = fullSheetHeader(app, title: "Feedback")
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://guard")!)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: feedback)], timeout: 10), .completed, "A native redirect must make the selected Guard stack visible over the inactive Settings route.")
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        XCTAssertTrue(activity.isHittable)
        capture(app, "Native Guard redirect leaves the deep-linked Feedback page inactive")

    }
    func testCustomizationUsesNativePersistenceAcrossRelaunch() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Customization"].tap()
        let guardPreview = app.buttons["Choose Lava Guard"]
        XCTAssertTrue(guardPreview.waitForExistence(timeout: 10))
        waitForSettledFrame(guardPreview)
        XCTAssertTrue(guardPreview.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(guardPreview.frame.height, 44)
        XCTAssertGreaterThanOrEqual(guardPreview.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(guardPreview.frame.maxX, app.frame.maxX)
        let selectedGuardLabel = guardPreview.label
        XCTAssertFalse(selectedGuardLabel.isEmpty)
        XCTAssertNotEqual(selectedGuardLabel, "Choose Lava Guard", "The actual Guard row announces its title and subtitle.")
        let selectedGuardHeight = guardPreview.frame.height
        let guardAccessory = app.descendants(matching: .any)["customization.guard.accessory"].firstMatch
        XCTAssertTrue(guardAccessory.exists)
        XCTAssertEqual(guardAccessory.frame.width, 12, accuracy: 1)
        XCTAssertTrue(guardPreview.frame.contains(guardAccessory.frame), "The trailing accessory stays in its own slot when preview content stacks.")
        capture(app, "Customization actual Guard option row with navigation accessory")
        guardPreview.tap()
        let guardHeader = fullSheetHeader(app, title: "Lava Guard")
        XCTAssertTrue(guardHeader.waitForExistence(timeout: 10))
        let selectedOption = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "guardian.option.", selectedGuardLabel)).firstMatch
        XCTAssertTrue(selectedOption.waitForExistence(timeout: 10))
        XCTAssertTrue(selectedOption.isSelected)
        XCTAssertEqual(selectedOption.frame.height, selectedGuardHeight, accuracy: 1, "Equivalent Guard content uses the same row anatomy in both destinations.")
        capture(app, "Lava Guard active-content spotlight and matching catalog row")
        // Spotlight illustration alignment/content-fit is inspected in this
        // actual capture; decorative SwiftUI/RN AX unions are not layout bounds.
        guardHeader.buttons["Close"].tap()
        XCTAssertTrue(guardPreview.waitForExistence(timeout: 10))
        // The English catalog renders the source key "App Haptics" as "App haptics".
        let haptics = app.switches["App haptics"]
        for _ in 0..<5 where !haptics.isHittable { scrollCustomizationUp(app) }
        XCTAssertTrue(haptics.isHittable, app.debugDescription)
        waitForSettledFrame(haptics)
        // The shared control owns one VoiceOver element: its UIKit switch.
        // The visual label deliberately has no separate StaticText AX target.
        // Measure the real control, never a padded container's AX union.
        XCTAssertGreaterThan(haptics.frame.width, 0)
        XCTAssertGreaterThan(haptics.frame.height, 0)
        XCTAssertTrue(app.frame.contains(haptics.frame))
        XCTAssertGreaterThanOrEqual(haptics.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1)
        XCTAssertLessThanOrEqual(haptics.frame.maxY, app.tabBars.firstMatch.frame.minY + 1)
        let before = haptics.value as? String
        haptics.tap()
        let expected = before == "1" ? "0" : "1"
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: haptics)], timeout: 5), .completed)
        app.terminate()
        app.launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Customization"].tap()
        for _ in 0..<5 where !haptics.isHittable { scrollCustomizationUp(app) }
        XCTAssertEqual(haptics.value as? String, expected)
        capture(app, "Native haptic preference persisted through relaunch")
        haptics.tap()
    }
    func testLiveActivityPauseStepperPersistsNonPresetMinutes() throws {
        let app = launch()
        func openCustomization() {
            nativeTab(app, "Settings").tap()
            app.buttons["row.Customization"].tap()
            let toggle = app.switches["Use Live Activities"]
            for _ in 0..<5 where !toggle.isHittable {
                scrollCustomizationUp(app)
            }
            XCTAssertTrue(toggle.isHittable, app.debugDescription)
        }
        openCustomization()
        let toggle = app.switches["Use Live Activities"]
        let wasEnabled = toggle.value as? String == "1"
        if !wasEnabled { toggle.tap() }
        let stepper = app.steppers["Live Activity pause length"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 where !stepper.isHittable { app.swipeUp() }
        let original = try XCTUnwrap(Int(stepper.value as? String ?? ""))
        let target = original == 7 ? 8 : 7
        func adjust(from: Int, to: Int) {
            guard from != to else { return }
            let direction = from < to ? 1 : -1
            for value in stride(from: from + direction, through: to, by: direction) {
                stepper.buttons["Live Activity pause length-" + (direction > 0 ? "Increment" : "Decrement")].tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", String(value)), object: stepper)], timeout: 5), .completed)
            }
        }
        adjust(from: original, to: target)
        capture(app, "Native Live Activity pause stepper with non-preset minutes")
        app.terminate()
        app.launch()
        openCustomization()
        XCTAssertTrue(stepper.waitForExistence(timeout: 10))
        for _ in 0..<3 where !stepper.isHittable { app.swipeUp() }
        XCTAssertEqual(stepper.value as? String, String(target))
        adjust(from: target, to: original)
        if !wasEnabled { toggle.tap() }
    }
    func testCustomDNSRapidURLTypingPreservesRepeatedCharacters() throws {
        let app = launch(paidPlan: true)
        nativeTab(app, "Settings").tap()
        let dns = app.buttons["connection.dns"]
        scrollFullyIntoView(app, dns); dns.tap()
        app.navigationBars["DNS settings"].buttons["Edit"].tap()
        let deviceDNS = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Device DNS")).firstMatch
        XCTAssertTrue(deviceDNS.waitForExistence(timeout: 10)); deviceDNS.tap()
        XCTAssertTrue(app.navigationBars.buttons["Add custom DNS"].waitForExistence(timeout: 10)); app.navigationBars.buttons["Add custom DNS"].tap()
        let name = app.textFields["Custom DNS"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); waitForSettledFrame(name); name.tap()
        name.typeText("Synthetic repeated URL typing")
        XCTAssertEqual(name.value as? String, "Synthetic repeated URL typing")
        let primary = app.textFields["IPv4/6, https://, tls://, doq://, quic://, or sdns://"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10)); waitForSettledFrame(primary); primary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: primary)], timeout: 10), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10)); waitForSettledFrame(app.keyboards.firstMatch, requiresHittable: false)
        for index in 1...3 {
            let value = "https://dns.example.test/dns-query?repeat=\(index)"
            let previous = index == 1 ? "" : primary.value as? String ?? ""
            primary.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
            XCTAssertEqual(primary.value as? String, value, "Every repeated URL character must survive the complete typing burst.")
        }
        capture(app, "Custom DNS rapid repeated URL input remains exact")
        app.navigationBars["Custom DNS"].buttons["Close"].tap()
        XCTAssertTrue(app.textFields["Search DNS providers or transports"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Close"].tap()
        app.navigationBars["DNS settings"].buttons["Cancel editing"].tap()
        XCTAssertTrue(app.navigationBars["DNS settings"].buttons["Edit"].waitForExistence(timeout: 10))
    }

    func testProtectedForegroundFormsRetainDraftsBehindReauthorization() throws {
        let app = launch(paidPlan: true)
        nativeTab(app, "Settings").tap()
        app.buttons["row.Security"].tap()
        let passcode = app.switches["Passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        XCTAssertEqual(passcode.value as? String, "0", "Use the task-private simulator's empty security fixture.")
        passcode.tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
        let editFilters = app.switches["Edit filters"]
        scrollFullyIntoView(app, editFilters)
        if editFilters.value as? String == "0" { editFilters.tap() }
        let settings = app.switches["Change settings"]
        scrollFullyIntoView(app, settings)
        if settings.value as? String == "0" { settings.tap() }
        let openLava = app.switches["Open Lava"]
        scrollFullyIntoView(app, openLava)
        if openLava.value as? String == "1" { openLava.tap(); enterPasscode(app) }
        nativeBack(app).tap()

        func revokeAndResume(_ name: XCUIElement, privateFields: [XCUIElement] = [], coverID: String, phase: String) {
            // Revealing a focused Content editor can scroll its Name above the
            // bar. Backgrounding needs stable identity, without touching Name.
            waitForSettledFrame(name, requiresHittable: false)
            XCUIDevice.shared.press(.home)
            let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed)
            app.activate()
            let prompt = app.staticTexts["Enter passcode"]
            let cover = app.otherElements[coverID]
            let reentry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                prompt.exists || cover.exists
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [reentry], timeout: 15), .completed)
            XCTAssertFalse(name.exists, "Protected draft fields must leave the accessibility tree on resume.")
            for field in privateFields { XCTAssertFalse(field.exists, "Every protected input must be concealed on resume.") }
            if !prompt.exists {
                capture(app, "\(phase) concealed before explicit authorization")
                let unlock = cover.buttons["Unlock Lava"]
                XCTAssertTrue(unlock.waitForExistence(timeout: 10))
                unlock.tap()
            }
            XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 15))
            XCTAssertFalse(name.exists, "Protected draft fields must leave the accessibility tree before reauthorization.")
            for field in privateFields { XCTAssertFalse(field.exists, "Every protected input must be concealed during authorization.") }
            capture(app, "\(phase) concealed behind native authorization")
            app.navigationBars["Authentication"].buttons["Cancel"].tap()
            XCTAssertTrue(app.buttons["Unlock Lava"].waitForExistence(timeout: 10))
            let retry = app.buttons["Unlock Lava"]
            let retryReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in retry.isHittable }, object: retry)
            let retryResult = XCTWaiter.wait(for: [retryReady], timeout: 10)
            capture(app, "\(phase) cancellation offers an interactive retry")
            XCTAssertEqual(retryResult, .completed, "The shared lock must remain interactive after cancellation.")
            XCTAssertFalse(name.exists, "Cancelling authorization cannot restore protected fields.")
            for field in privateFields { XCTAssertFalse(field.exists, "Cancelling authorization cannot reveal another input.") }
            app.buttons["Unlock Lava"].tap()
            enterPasscode(app)
            XCTAssertTrue(name.waitForExistence(timeout: 15), "The same retained form must reappear after authorization.")
            capture(app, "\(phase) retained draft after explicit reauthorization")
        }
        func focusForRapidTyping(_ field: XCUIElement) {
            waitForSettledFrame(field); field.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)], timeout: 10), .completed)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            waitForSettledFrame(app.keyboards.firstMatch, requiresHittable: false)
        }

        let dnsEntry = app.buttons["connection.dns"]
        scrollFullyIntoView(app, dnsEntry)
        waitForSettledFrame(dnsEntry)
        dnsEntry.tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 5) { enterPasscode(app) }
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["Device DNS"].waitForExistence(timeout: 10))
        let savedDeviceDNSValue = try XCTUnwrap(app.switches["Device DNS"].value as? String)
        app.navigationBars.buttons["Edit"].tap()
        let deviceDNS = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Device DNS")).firstMatch
        XCTAssertTrue(deviceDNS.waitForExistence(timeout: 10))
        deviceDNS.tap()
        XCTAssertTrue(app.navigationBars.buttons["Add custom DNS"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Add custom DNS"].tap()
        let dnsName = app.textFields["Custom DNS"]
        XCTAssertTrue(dnsName.waitForExistence(timeout: 10))
        waitForSettledFrame(dnsName)
        dnsName.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: dnsName)], timeout: 10), .completed)
        dnsName.typeText("Retained protected DNS draft")
        XCTAssertEqual(dnsName.value as? String, "Retained protected DNS draft", "Rapid typing must be intact before any lifecycle transition.")
        let primaryDNS = app.textFields["IPv4/6, https://, tls://, doq://, quic://, or sdns://"]
        XCTAssertTrue(primaryDNS.waitForExistence(timeout: 10))
        focusForRapidTyping(primaryDNS); primaryDNS.typeText("https://dns.example.test/dns-query")
        XCTAssertEqual(primaryDNS.value as? String, "https://dns.example.test/dns-query")
        revokeAndResume(dnsName, privateFields: [primaryDNS], coverID: "custom-entry-privacy-cover", phase: "Custom DNS")
        XCTAssertEqual(dnsName.value as? String, "Retained protected DNS draft")
        XCTAssertEqual(primaryDNS.value as? String, "https://dns.example.test/dns-query")
        let saveCustomDNS = app.scrollViews.containing(.textField, identifier: "Custom DNS").firstMatch.buttons["Save"]
        scrollFullyIntoView(app, saveCustomDNS); saveCustomDNS.tap()
        XCTAssertTrue(app.textFields["Search DNS providers or transports"].waitForExistence(timeout: 10))
        let selectedDNS = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Retained protected DNS draft")).firstMatch
        XCTAssertTrue(selectedDNS.waitForExistence(timeout: 10), "The original picker must receive the authorized native custom draft.")
        let saveDNSSelection = app.buttons["Save selection"]
        scrollFullyIntoView(app, saveDNSSelection, presentedSheet: app.navigationBars["Choose DNS"]); saveDNSSelection.tap()
        XCTAssertTrue(selectedDNS.waitForExistence(timeout: 10), "The same parent tier draft must receive the custom selection.")
        let cancelDNS = app.navigationBars["DNS settings"].buttons["Cancel editing"]
        XCTAssertTrue(cancelDNS.waitForExistence(timeout: 10)); cancelDNS.tap()
        let discardDNS = app.alerts["Discard changes?"].buttons["Discard"]
        XCTAssertTrue(discardDNS.waitForExistence(timeout: 10)); discardDNS.tap()
        XCTAssertTrue(app.navigationBars["DNS settings"].buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["Device DNS"].value as? String, savedDeviceDNSValue, "Discarding the custom form cannot change the saved DNS choice.")
        XCTAssertFalse(app.staticTexts["Retained protected DNS draft"].exists)
        nativeBack(app).tap()

        let vpn = app.buttons["connection.vpn"]
        scrollFullyIntoView(app, vpn)
        vpn.tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 5) { enterPasscode(app) }
        let setup = app.descendants(matching: .any).matching(identifier: "vpn.setup-toggle").firstMatch.switches.firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let originalSetup = setup.value as? String
        if originalSetup == "0" { setup.tap() }
        let empty = app.staticTexts["No configurations"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "No saved credentials are admitted to this test.")
        app.navigationBars["VPN chaining"].buttons["Edit"].tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 5) { enterPasscode(app) }
        let add = app.buttons["Add configuration"]
        scrollFullyIntoView(app, add)
        XCTAssertTrue(add.isEnabled)
        add.tap()
        let vpnName = app.textFields["Configuration name"]
        XCTAssertTrue(vpnName.waitForExistence(timeout: 10))
        waitForSettledFrame(vpnName)
        vpnName.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: vpnName)], timeout: 10), .completed)
        vpnName.typeText("Retained protected VPN draft")
        XCTAssertEqual(vpnName.value as? String, "Retained protected VPN draft")
        let content = app.textViews.firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        let comment = "# Retained synthetic comment; no keys or endpoint"
        focusForRapidTyping(content); content.typeText(comment)
        XCTAssertEqual(content.value as? String, comment)
        revokeAndResume(vpnName, privateFields: [content], coverID: "vpn-editor-privacy-cover", phase: "WireGuard")
        XCTAssertEqual(vpnName.value as? String, "Retained protected VPN draft")
        XCTAssertFalse(content.exists, "Authorization alone cannot reveal a private native configuration buffer.")
        let reveal = app.buttons["Show configuration"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10))
        reveal.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        XCTAssertEqual(content.value as? String, comment, "Reauthorization must retain the same opaque native input owner.")
        app.navigationBars["WireGuard configuration"].buttons["Cancel"].tap()
        let discard = app.alerts["Discard changes?"].buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.tap()
        XCTAssertTrue(app.navigationBars["WireGuard configuration"].waitForNonExistence(timeout: 10))
        let cancelVPN = app.navigationBars["VPN chaining"].buttons["Cancel editing"]
        waitForSettledFrame(cancelVPN)
        cancelVPN.tap()
        XCTAssertTrue(cancelVPN.waitForNonExistence(timeout: 10))
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "Discard cannot create a saved configuration.")
        if originalSetup == "0" {
            scrollFullyIntoView(app, setup)
            tapNativeSwitch(setup)
            if app.staticTexts["Enter passcode"].waitForExistence(timeout: 3) { enterPasscode(app) }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                setup.value as? String == originalSetup
            }, object: nil)], timeout: 10), .completed)
        }
        let vpnBack = nativeBack(app)
        XCTAssertTrue(vpnBack.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(vpnBack)
        vpnBack.tap()

        nativeTab(app, "Guard").tap()
        app.buttons["guard.filter"].tap()
        app.buttons["row.Switch or manage filters"].tap()
        XCTAssertTrue(app.buttons["Core"].waitForExistence(timeout: 10))
        app.buttons["Core"].tap()
        let viewOnly = app.buttons["View or edit only"]
        XCTAssertTrue(viewOnly.waitForExistence(timeout: 10))
        waitForSettledFrame(viewOnly)
        viewOnly.tap()
        XCTAssertTrue(viewOnly.waitForNonExistence(timeout: 10), "Selecting the settled native action must close the choice sheet.")
        // Library and detail both expose Edit; wait for detail's own identity
        // before addressing its toolbar after the asynchronous native open.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "filter.identity.name", "Core")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Edit"].tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 5) { enterPasscode(app) }
        let addList = app.buttons["Add a blocklist"]
        XCTAssertTrue(addList.waitForExistence(timeout: 10), app.debugDescription)
        scrollFullyIntoView(app, addList); addList.tap()
        XCTAssertTrue(app.navigationBars.buttons["Add your own blocklist"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Add your own blocklist"].tap()
        let sourceName = app.textFields["My blocklist"]
        XCTAssertTrue(sourceName.waitForExistence(timeout: 10))
        waitForSettledFrame(sourceName); sourceName.tap(); sourceName.typeText("Retained protected source")
        XCTAssertEqual(sourceName.value as? String, "Retained protected source")
        let sourceURL = app.textFields["https://example.com/pi-hole-style-list.txt"]
        XCTAssertTrue(sourceURL.waitForExistence(timeout: 10))
        focusForRapidTyping(sourceURL); sourceURL.typeText("https://example.com/lava-synthetic-review.txt")
        XCTAssertEqual(sourceURL.value as? String, "https://example.com/lava-synthetic-review.txt")
        revokeAndResume(sourceName, privateFields: [sourceURL], coverID: "custom-entry-privacy-cover", phase: "Custom blocklist")
        XCTAssertEqual(sourceName.value as? String, "Retained protected source")
        XCTAssertEqual(sourceURL.value as? String, "https://example.com/lava-synthetic-review.txt")
        // Stage a public synthetic URL without saving the filter or fetching it.
        // This exercises the retained native parent epoch, not just local text.
        let addSource = app.buttons["Add blocklist"]
        scrollFullyIntoView(app, addSource); addSource.tap()
        // Entry editing and viewing the originating filter are independent
        // native security surfaces. Backgrounding revoked the latter too.
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 5) { enterPasscode(app) }
        XCTAssertTrue(app.textFields["Search blocklists or categories"].waitForExistence(timeout: 10))
        XCTAssertFalse(sourceName.exists)
        let sourcePickerHeader = fullSheetHeader(app, title: "Choose blocklists")
        XCTAssertTrue(sourcePickerHeader.waitForExistence(timeout: 10))
        let closeSourcePicker = sourcePickerHeader.buttons["Close"]
        XCTAssertTrue(closeSourcePicker.wait(for: \.isHittable, toEqual: true, timeout: 10))
        waitForSettledFrame(closeSourcePicker); closeSourcePicker.tap()
        XCTAssertTrue(sourcePickerHeader.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Retained protected source"].waitForExistence(timeout: 10))
        let cancelSource = app.navigationBars.buttons["Cancel editing"]
        XCTAssertTrue(cancelSource.wait(for: \.isHittable, toEqual: true, timeout: 10))
        waitForSettledFrame(cancelSource); cancelSource.tap()
        let discardSource = app.alerts["Discard changes?"].buttons["Discard"]
        XCTAssertTrue(discardSource.waitForExistence(timeout: 10)); discardSource.tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Retained protected source"].exists)
        nativeBack(app).tap()
        XCTAssertTrue(app.buttons["Core"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Edit"].tap()
        if app.staticTexts["Enter passcode"].waitForExistence(timeout: 5) { enterPasscode(app) }
        XCTAssertTrue(app.navigationBars.buttons["Close edit mode"].waitForExistence(timeout: 10))
        app.buttons["filter.library.filter-essential"].tap()
        let rename = app.textFields["Filter name"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        let savedName = rename.value as? String ?? ""
        focusForRapidTyping(rename)
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: savedName.count) + "Retained protected rename")
        revokeAndResume(rename, coverID: "foreground-flow-privacy-cover", phase: "Library rename")
        XCTAssertEqual(rename.value as? String, "Retained protected rename")
        app.navigationBars["Rename filter"].buttons["Cancel"].tap()
        let discardRename = app.alerts["Discard changes?"].buttons["Discard"]
        XCTAssertTrue(discardRename.waitForExistence(timeout: 10))
        discardRename.tap()
        XCTAssertTrue(app.navigationBars["Rename filter"].waitForNonExistence(timeout: 10))
        let closeLibrary = app.navigationBars["Your filters"].buttons["Close edit mode"]
        waitForSettledFrame(closeLibrary)
        closeLibrary.tap()
        XCTAssertTrue(closeLibrary.waitForNonExistence(timeout: 10), "Closing the retained library editor must complete before leaving its tab.")
        XCTAssertTrue(app.buttons[savedName].waitForExistence(timeout: 10), "Discard cannot change the saved filter identity.")
        XCTAssertFalse(app.buttons["Retained protected rename"].exists)
        nativeTab(app, "Settings").tap()
        // Backgrounding invalidated Settings-entry authorization. Complete
        // that native gate before asking the protected Security row to open.
        enterPasscode(app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: nativeTab(app, "Settings"))], timeout: 10), .completed)
        let security = app.buttons["row.Security"]
        XCTAssertTrue(security.waitForExistence(timeout: 10))
        security.tap()
        enterPasscode(app)
        passcode.tap()
        enterPasscode(app)
        XCTAssertEqual(passcode.value as? String, "0")
        nativeTab(app, "Guard").tap()
        // Switching tabs retains Guard -> Filters -> Your filters. Return
        // through both native Back actions before inspecting root protection.
        XCTAssertTrue(app.navigationBars["Your filters"].waitForExistence(timeout: 10))
        waitForSettledFrame(app.navigationBars["Your filters"])
        waitForSettledFrame(nativeBack(app))
        nativeBack(app).tap()
        XCTAssertTrue(app.navigationBars["Your filters"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 10))
        waitForSettledFrame(app.navigationBars["Filters"])
        XCTAssertTrue(app.buttons["row.Now filtering"].waitForExistence(timeout: 10))
        waitForSettledFrame(nativeBack(app))
        nativeBack(app).tap()
        XCTAssertTrue(app.buttons["guard.filter"].waitForExistence(timeout: 10))
        assertRound8GuardIsOff(app)
    }

    func testProtectedDNSContextualReturnAfterBackground() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Security"].tap()
        let passcode = app.switches["Passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        XCTAssertEqual(passcode.value as? String, "0", "Use the isolated QA simulator.")
        passcode.tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        app.typeText("1234")
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
        let settings = app.switches["Change settings"]
        for _ in 0..<4 where !settings.isHittable { app.swipeUp() }
        if settings.value as? String == "0" { settings.tap() }
        let unlock = app.switches["Open Lava"]
        if unlock.value as? String == "1" {
            for _ in 0..<4 where !unlock.isHittable { app.swipeDown() }
            unlock.tap()
            enterPasscode(app)
        }
        nativeBack(app).tap()
        // DNS no longer carries a promotional Explore row. Follow the actual
        // Settings connection invitation, then open its protected DNS destination.
        let explore = app.buttons["Explore this connection"]
        for _ in 0..<4 where !explore.isHittable { app.swipeDown() }
        XCTAssertTrue(explore.isHittable)
        explore.tap()
        enterPasscode(app)
        let playground = app.scrollViews.containing(.button, identifier: "explore.play").element
        XCTAssertTrue(playground.waitForExistence(timeout: 10))
        playground.buttons["connection.dns"].tap()
        let configure = app.buttons["explore.configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 10))
        XCTAssertEqual(configure.label, "Open DNS settings")
        XCUIDevice.shared.press(.home)
        app.activate()
        scrollFullyIntoView(app, configure, throughGutter: true)
        configure.tap()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        capture(app, "Explore DNS entry waits for fresh native authentication after background")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["DNS settings"].exists, "Cancelling authorization must not open a protected DNS page.")
        configure.tap()
        enterPasscode(app)
        let device = app.switches["Device DNS"]
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        let savedDeviceChoice = try XCTUnwrap(device.value as? String)
        nativeBack(app).tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        scrollFullyIntoView(app, configure, throughGutter: true)
        configure.tap()
        enterPasscode(app)
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        XCTAssertEqual(device.value as? String, savedDeviceChoice)
        // Wait for the authenticated push to settle, then use the same explicit
        // edge-drag recipe as the Activity interactive-back journey. Returning
        // must not preserve authorization across another foreground visit.
        waitForSettledFrame(device)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.55))
        edge.press(forDuration: 0.05, thenDragTo: destination,
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        scrollFullyIntoView(app, configure, throughGutter: true)
        configure.tap()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 10))
        capture(app, "Protected DNS entry remains gated after native swipe and background")
        nativeBack(app).tap()
        XCTAssertTrue(app.buttons["row.Security"].waitForExistence(timeout: 10))
        app.buttons["row.Security"].tap()
        enterPasscode(app)
        passcode.tap()
        enterPasscode(app)
        XCTAssertEqual(passcode.value as? String, "0")
    }

    func testSecurityLockResumesOneVisitWithOnePasscodeAndUsableRetry() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Security"].tap()
        let passcode = app.switches["Passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        XCTAssertEqual(passcode.value as? String, "0")
        passcode.tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        let unlock = app.switches["Open Lava"]
        scrollFullyIntoView(app, unlock)
        unlock.tap()
        XCTAssertEqual(unlock.value as? String, "1")
        nativeBack(app).tap()
        app.buttons["row.Security"].tap()
        enterPasscode(app) // One tap must land on the intended credential screen.
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))

        func background() {
            XCUIDevice.shared.press(.home)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: app)], timeout: 10), .completed)
            app.activate()
            XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        }
        func assertRestored(_ phase: String) {
            XCTAssertTrue(passcode.waitForExistence(timeout: 10), app.debugDescription)
            scrollFullyIntoView(app, passcode)
            XCTAssertTrue(passcode.isHittable, "Successful unlock must reveal the retained Security screen")
            XCTAssertFalse(app.otherElements["lavaPrivacyShield"].exists)
            XCTAssertFalse(app.otherElements["securityLockOverlay"].exists)
            XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1), "No second credential prompt")
            XCTAssertTrue(passcode.isHittable)
            capture(app, phase)
        }
        for cycle in 1...3 {
            background()
            enterPasscode(app)
            assertRestored("Security restored with one passcode, cycle \(cycle)")
        }
        background()
        app.navigationBars["Authentication"].buttons["Cancel"].tap()
        let retry = app.buttons["Unlock Lava"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        capture(app, "One interactive lock after authentication cancellation")
        XCTAssertEqual(app.buttons.matching(identifier: "Unlock Lava").count, 1, "The scene must have one lock presenter.")
        XCTAssertTrue(retry.isHittable, "Cancellation must leave a usable lock, never a blank shield. \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1), "No automatic retry after cancellation")
        retry.tap()
        enterPasscode(app)
        assertRestored("Security restored after explicit retry")
        nativeBack(app).tap()
        app.buttons["row.Security"].tap()
        enterPasscode(app)
        XCTAssertTrue(passcode.waitForExistence(timeout: 10), "A later visit still requires credentials and proceeds on the first tap")
        let activityProtection = app.switches["View Activity"]
        scrollFullyIntoView(app, activityProtection)
        if activityProtection.value as? String == "0" { activityProtection.tap() }
        nativeBack(app).tap()
        nativeTab(app, "Guard").tap()
        let today = app.buttons["guard.today"]
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        background()
        enterPasscode(app)
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        XCTAssertTrue(today.isHittable, "Unlocking Guard must reveal working content, never an empty screen.")
        capture(app, "Guard restored after one unlock")
        today.tap()
        enterPasscode(app)
        let periods = app.segmentedControls["activity.period"]
        XCTAssertTrue(periods.waitForExistence(timeout: 10), "Activity entry must finish after one tap and one authentication.")
        periods.buttons["Month"].tap()
        background()
        enterPasscode(app)
        XCTAssertTrue(periods.waitForExistence(timeout: 10))
        XCTAssertTrue(periods.buttons["Month"].isSelected, "The same Activity visit must resume with its selected period.")
        XCTAssertTrue(periods.isHittable)
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))
        capture(app, "Activity restores the selected period with one unlock")
        app.launchEnvironment["LAVA_UI_TEST_RESET_SECURITY"] = "0"
        app.terminate()
        app.launch()
        enterPasscode(app)
        XCTAssertTrue(today.waitForExistence(timeout: 10), "Cold launch must reveal Guard after one unlock.")
        XCTAssertTrue(today.isHittable)
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))
        capture(app, "Cold launch reveals Guard after one unlock")
    }

    func testNativePasscodeSetupAndAuthenticationAboveReactSheet() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Security"].tap()
        let passcode = app.switches["Passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        XCTAssertEqual(passcode.value as? String, "0", "Run this journey on its dedicated clean simulator.")
        passcode.tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        app.typeText("1234")
        XCTAssertTrue(passcode.waitForExistence(timeout: 10))
        XCTAssertEqual(passcode.value as? String, "1")
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
        let settings = app.switches["Change settings"]
        for _ in 0..<4 where !settings.isHittable { app.swipeUp() }
        if settings.value as? String == "0" { settings.tap() }
        let unlock = app.switches["Open Lava"]
        if unlock.value as? String == "1" {
            for _ in 0..<4 where !unlock.isHittable { app.swipeDown() }
            unlock.tap()
            enterPasscode(app)
        }
        nativeBack(app).tap()
        app.buttons["row.Customization"].tap()
        enterPasscode(app)
        app.buttons["Choose Lava Guard"].tap()
        XCTAssertTrue(fullSheetHeader(app, title: "Lava Guard").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Enter passcode"].exists, "Nested navigation retains the parent settings grant.")
        let icon = app.switches["Match app icon to Lava Guard"]
        for _ in 0..<5 where !icon.isHittable { app.swipeUp() }
        XCTAssertTrue(icon.isHittable, app.debugDescription)
        let before = icon.value as? String
        // The protected settings visit is retained beneath the shared lock even
        // when the separate whole-app entry gate is off.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "Native authentication above the React Guard sheet")
        app.buttons["Cancel"].tap()
        let retry = app.buttons["Unlock Lava"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        enterPasscode(app)
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        XCTAssertEqual(icon.value as? String, before, "Cancelling authentication must leave the setting unchanged.")
        fullSheetHeader(app, title: "Lava Guard").buttons["Close"].tap()
        nativeBack(app).tap()
        let upgrade = app.buttons["row.Get Lava Plus today"]
        for _ in 0..<5 where !upgrade.isHittable { app.swipeDown() }
        XCTAssertTrue(upgrade.isHittable, app.debugDescription)
        upgrade.tap()
        enterPasscode(app)
        let restore = app.buttons["Restore purchase"]
        XCTAssertTrue(restore.waitForExistence(timeout: 20), app.debugDescription)
        for _ in 0..<7 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable, app.debugDescription)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5), "The protected purchase visit must reauthenticate after backgrounding.")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        enterPasscode(app)
        waitForSettledFrame(restore)
        nativeBack(app).tap()

        let vpn = app.buttons["connection.vpn"]
        for _ in 0..<5 where !vpn.isHittable { app.swipeDown() }
        XCTAssertTrue(vpn.isHittable, app.debugDescription)
        vpn.tap()
        enterPasscode(app)
        let protectedSetup = app.descendants(matching: .any).matching(identifier: "vpn.setup-toggle").firstMatch.switches.firstMatch
        XCTAssertTrue(protectedSetup.waitForExistence(timeout: 10))
        XCTAssertEqual(protectedSetup.value as? String, "0", "Free users stop at the VPN prerequisite.")
        let protectedSetupValue = protectedSetup.value as? String
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.55)),
                   withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.3)
        waitForSettledFrame(protectedSetup)
        XCTAssertFalse(app.staticTexts["Enter passcode"].exists, "Cancelled Back keeps the current native page authorization.")
        XCTAssertEqual(protectedSetup.value as? String, protectedSetupValue)
        tapNativeSwitch(protectedSetup)
        let nativePlus = app.navigationBars["Lava Plus"]
        XCTAssertTrue(nativePlus.waitForExistence(timeout: 10))
        nativePlus.buttons.firstMatch.tap()
        let returnPromptAppeared = app.staticTexts["Enter passcode"].waitForExistence(timeout: 10)
        if !returnPromptAppeared {
            capture(app, "Native child return missing authentication")
            var observations = [app.debugDescription]
            let setup = app.descendants(matching: .any).matching(identifier: "vpn.setup-toggle").firstMatch.switches.firstMatch
            observations.append("setup exists=\(setup.exists) hittable=\(setup.isHittable)")
            let receipt = XCTAttachment(string: observations.joined(separator: "\n"))
            receipt.name = "Native child return admission diagnostic — isolated QA simulator"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
        XCTAssertTrue(returnPromptAppeared,
            "Returning from a native child must reauthorize a revoked Settings turn.")
        XCTAssertFalse(protectedSetup.exists, "Protected native controls must leave the accessibility tree while authentication is pending.")
        capture(app, "Native child return requires authentication with controls closed")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "Cancelling must leave the protected native page, not expose editable controls.")
        // Settings exists under the native page before its automatic pop finishes.
        // Wait for dismissal and the restored row geometry before requesting access
        // again, otherwise the transition can consume the tap without opening auth.
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForNonExistence(timeout: 10))
        for _ in 0..<5 where !vpn.isHittable { app.swipeDown() }
        waitForSettledFrame(vpn)
        vpn.tap()
        enterPasscode(app)
        XCTAssertEqual(protectedSetup.value as? String, protectedSetupValue,
                       "Cancelled child-return authentication must preserve the setting.")
        XCTAssertTrue(protectedSetup.waitForExistence(timeout: 10))
        tapNativeSwitch(protectedSetup)
        XCTAssertTrue(nativePlus.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        enterPasscode(app)
        XCTAssertTrue(nativePlus.waitForExistence(timeout: 10))
        nativePlus.buttons.firstMatch.tap()
        enterPasscode(app)
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        capture(app, "Native VPN reauthorizes after its Plus page and backgrounding")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10),
            "The native VPN page also reauthorizes when resumed directly.")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        enterPasscode(app)
        XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
        nativeBack(app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let securityRow = app.buttons["row.Security"]
        for _ in 0..<5 where !securityRow.isHittable { app.swipeDown() }
        waitForSettledFrame(securityRow)
        securityRow.tap()
        enterPasscode(app)
        for _ in 0..<4 where !settings.isHittable { app.swipeUp() }
        settings.tap()
        enterPasscode(app)
        let filterProtection = app.switches["Edit filters"]
        for _ in 0..<5 where !filterProtection.isHittable { app.swipeDown() }
        XCTAssertTrue(filterProtection.isHittable, app.debugDescription)
        if filterProtection.value as? String == "0" { filterProtection.tap() }
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://guard")!)
        let filters = app.buttons["guard.filter"]
        XCTAssertTrue(filters.waitForExistence(timeout: 10))
        filters.tap()
        app.buttons["row.Switch or manage filters"].tap()
        app.buttons["Core"].tap()
        let viewOnly = app.buttons["View or edit only"]
        XCTAssertTrue(viewOnly.waitForExistence(timeout: 10))
        waitForSettledFrame(viewOnly)
        viewOnly.tap()
        XCTAssertTrue(viewOnly.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "filter.identity.name", "Core")).firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons["Edit"].tap()
        enterPasscode(app)
        let add = app.buttons["Block a domain"]
        for _ in 0..<5 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable, app.debugDescription)
        add.tap()
        XCTAssertTrue(app.buttons["Add domain"].waitForExistence(timeout: 10))
        let discardedDomain = "rn-discard-" + UUID().uuidString.lowercased() + ".invalid"
        app.typeText(discardedDomain)
        app.buttons["Add domain"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "filter.identity.name", "Core")).firstMatch.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        enterPasscode(app)
        let cancelEditing = app.navigationBars.buttons["Cancel editing"]
        XCTAssertTrue(cancelEditing.waitForExistence(timeout: 10))
        cancelEditing.tap()
        let discard = app.alerts.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10), "Discard must not demand another authentication after the protected visit resumes.")
        XCTAssertFalse(app.staticTexts["Enter passcode"].exists)
        XCTAssertFalse(app.staticTexts[discardedDomain].exists)
        capture(app, "Filter draft discarded after background without reauthentication")
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings")!)
        XCTAssertTrue(app.buttons["row.Security"].waitForExistence(timeout: 10))
        app.buttons["row.Security"].tap()
        enterPasscode(app) // Required even when Update App Settings is off.
        passcode.tap()
        enterPasscode(app)
        // Sheet dismissal precedes the command continuation and its RN snapshot.
        // Wait for the actual observable mutation, rather than treating dismissal
        // alone as completion of passcode removal.
        let removal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            passcode.value as? String == "0"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removal], timeout: 5), .completed)
        capture(app, "Passcode removal reaches its completed setting value")
    }
    func testProtectedImportDefersAuthenticationAndRecreatesAfterAppLock() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        app.buttons["row.Security"].tap()
        app.switches["Passcode"].tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        app.typeText("1234")
        XCTAssertTrue(app.switches["Passcode"].waitForExistence(timeout: 10))
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
        for name in ["Open Lava", "Edit filters"] {
            let toggle = app.switches[name]
            for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable, app.debugDescription)
            if toggle.value as? String == "0" { toggle.tap() }
            XCTAssertEqual(toggle.value as? String, "1")
        }
        nativeTab(app, "Guard").tap()
        app.buttons["guard.filter"].tap()
        let importFilter = app.navigationBars["Filters"].buttons["Import"]
        XCTAssertTrue(importFilter.waitForExistence(timeout: 10), app.debugDescription)
        importFilter.tap()
        let codeEntry = app.buttons["Enter a code"]
        XCTAssertTrue(codeEntry.waitForExistence(timeout: 10), "Reading an import must not require filter-editing authentication.")
        XCTAssertFalse(app.staticTexts["Enter passcode"].exists)
        codeEntry.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        app.typeText("LF1-private-in-progress")
        XCUIDevice.shared.press(.home)
        app.activate()
        enterPasscode(app)
        XCTAssertTrue(codeEntry.waitForExistence(timeout: 10), "Unlock must recreate the staged importer at its original entry point.")
        codeEntry.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse((editor.value as? String ?? "").contains("private-in-progress"), "The old input/scanner state must be torn down while locked.")
        capture(app, "Import recreated after App Unlock without retaining private input")
    }
    func testCompletedImportSurvivesPrivacyTeardownUntilDone() throws {
        let app = launch()
        let currentFilter = app.buttons["guard.filter"]
        // Re-import the inactive filter's own real payload, preserving the live
        // protection choice and contents while exercising the actual commit path.
        let targetName = currentFilter.label.contains("Core") ? "Balanced" : "Core"
        currentFilter.tap()
        let yourFilters = app.buttons["row.Switch or manage filters"]
        XCTAssertTrue(yourFilters.waitForExistence(timeout: 10))
        yourFilters.tap()
        let sharedFilter = app.buttons.matching(NSPredicate(format: "label == %@", targetName)).firstMatch
        XCTAssertTrue(sharedFilter.waitForExistence(timeout: 10), app.debugDescription)
        sharedFilter.tap()
        let shareInactive = app.sheets[targetName].buttons["Share"]
        XCTAssertTrue(shareInactive.waitForExistence(timeout: 10), "Share the inactive filter through its native choice sheet without applying it.")
        waitForSettledFrame(shareInactive)
        shareInactive.tap()
        let setupCode = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'LF1-'")).firstMatch
        for _ in 0..<4 where !setupCode.exists { app.swipeUp() }
        XCTAssertTrue(setupCode.waitForExistence(timeout: 20), "Use the native-generated code, never a fake successful-import fixture.")
        let code = setupCode.label
        fullSheetHeader(app, title: "Share your filter").buttons["Close"].tap()
        let libraryBack = app.navigationBars["Your filters"].buttons["BackButton"]
        XCTAssertTrue(libraryBack.waitForExistence(timeout: 10), app.debugDescription)
        libraryBack.tap()
        // Tab switching preserves each stack. Return Filters to Guard before
        // configuring security so the later Guard entry starts at its summary.
        let filtersBack = nativeBack(app)
        XCTAssertTrue(filtersBack.waitForExistence(timeout: 10), app.debugDescription)
        filtersBack.tap()
        XCTAssertTrue(currentFilter.waitForExistence(timeout: 10), app.debugDescription)

        nativeTab(app, "Settings").tap()
        app.buttons["row.Security"].tap()
        app.switches["Passcode"].tap()
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 10))
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        app.typeText("1234")
        XCTAssertTrue(app.switches["Passcode"].waitForExistence(timeout: 10))
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
        for name in ["Open Lava", "Edit filters"] {
            let toggle = app.switches[name]
            for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable, app.debugDescription)
            if toggle.value as? String == "0" { toggle.tap() }
            XCTAssertEqual(toggle.value as? String, "1")
        }
        nativeTab(app, "Guard").tap()
        app.buttons["guard.filter"].tap()
        let importFilter = app.navigationBars["Filters"].buttons["Import"]
        XCTAssertTrue(importFilter.waitForExistence(timeout: 10), app.debugDescription)
        importFilter.tap()
        let codeEntry = app.buttons["Enter a code"]
        XCTAssertTrue(codeEntry.waitForExistence(timeout: 10))
        codeEntry.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        app.typeText(code)
        app.buttons["Continue"].tap()
        let chooseReplacement = app.buttons["Replace a filter instead"]
        XCTAssertTrue(chooseReplacement.waitForExistence(timeout: 10), app.debugDescription)
        chooseReplacement.tap()
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", targetName)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(target.label.contains("In effect"), "This journey must leave the active filter untouched.")
        target.tap()
        let replace = app.buttons["Replace a filter"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10))
        replace.tap()
        enterPasscode(app)
        let completed = app.staticTexts["Filter imported"]
        XCTAssertTrue(completed.waitForExistence(timeout: 20), app.debugDescription)
        let message = app.staticTexts["The shared filter was added to Your filters as “\(targetName)”."]
        XCTAssertTrue(message.exists, "The success names the confirmed local filter.")
        capture(app, "Confirmed import awaiting Done")

        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed)
        app.activate()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
        XCTAssertFalse(completed.exists, "App Unlock must withhold the completed import as well as unfinished import content.")
        enterPasscode(app)
        XCTAssertTrue(completed.waitForExistence(timeout: 10), "A committed import must resume its result after privacy teardown.")
        XCTAssertTrue(message.exists)
        XCTAssertFalse(codeEntry.exists, "A completed import must never restart as a new import.")
        capture(app, "Confirmed import restored after App Unlock")
        app.buttons["Done"].tap()
        XCTAssertTrue(completed.waitForNonExistence(timeout: 10))
        XCTAssertTrue(importFilter.waitForExistence(timeout: 10))
    }

    private func openSudoku(_ mascot: XCUIElement, in app: XCUIApplication) {
        // XCTest idle waits can break the app's 0.5s inter-tap window under VM load (the window is
        // deliberately tight so the five taps must be consecutive), so a single cadence can miss;
        // retry the whole burst. Retry only entry, with pre-resolved coordinates and separate presses.
        let frame = mascot.frame
        let appFrame = app.frame
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.midX - appFrame.minX, dy: frame.midY - appFrame.minY)
        )
        for _ in 0..<5 {
            for _ in 0..<5 { center.tap() }
            if sudokuNotesControl(app).waitForExistence(timeout: 5) { return }
        }
        XCTFail("Five separate mascot taps did not open Sudoku.")
    }

    private func assertWindowOrientation(_ app: XCUIApplication, landscape: Bool) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard app.state == .runningForeground else { return false }
            let windows = app.windows.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
            return windows.contains { landscape ? $0.frame.width > $0.frame.height : $0.frame.height > $0.frame.width }
        }, object: nil)], timeout: 15)
        if result != .completed {
            capture(app, "Actual screen after orientation observation failed")
            let detail = XCTAttachment(string: "state=\(app.state.rawValue)\n\(app.debugDescription)")
            detail.name = "Foreground and window evidence after rotation"
            detail.lifetime = .keepAlways
            add(detail)
        }
        XCTAssertEqual(result, .completed, "A live foreground window must have the requested orientation.")
    }

    private func waitForSettledFrame(_ element: XCUIElement, requiresHittable: Bool = true) {
        var previous = CGRect.null
        var stableSamples = 0
        var samples: [CGRect] = []
        var sampleTimes: [TimeInterval] = []
        let started = ProcessInfo.processInfo.systemUptime
        // snapshot() exports the element's full child hierarchy. Read only its
        // frame here, retaining the hit test on every sample. The loaded CI VM
        // produced only two valid samples in 20 seconds; four are required for
        // three unchanged transitions, so allow 40 seconds plus scheduling slack.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard !requiresHittable || element.isHittable else {
                stableSamples = 0
                previous = .null
                return false
            }
            let frame = element.frame
            guard frame.width > 0, frame.height > 0,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }) else {
                stableSamples = 0
                previous = .null
                return false
            }
            samples.append(frame)
            sampleTimes.append(ProcessInfo.processInfo.systemUptime - started)
            let unchanged = abs(frame.minX - previous.minX) < 0.5 && abs(frame.minY - previous.minY) < 0.5
                && abs(frame.width - previous.width) < 0.5 && abs(frame.height - previous.height) < 0.5
            stableSamples = unchanged ? stableSamples + 1 : 0
            previous = frame
            return stableSamples >= 3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 45), .completed,
            "Expected three unchanged visible frame transitions; sampled \(samples) at \(sampleTimes) seconds: \(element.debugDescription)")
    }

    private func scrollRound8EditorFooterIntoView(_ app: XCUIApplication, editor: XCUIElement,
                                                action: XCUIElement, expectedDraft: String) throws {
        let input = app.textViews.firstMatch
        let keyboard = app.keyboards.firstMatch
        let editorContent = app.scrollViews.containing(.textView, identifier: "Content").firstMatch
        let footer = [editorContent.buttons["Choose file"].firstMatch, editorContent.buttons["Save"].firstMatch]
        var scrollSamples: [String] = []
        defer {
            let evidence = XCTAttachment(string: scrollSamples.joined(separator: "\n"))
            evidence.name = "Measured footer scroll corrections"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        func admittedViewport() throws -> CGRect {
            guard editor.exists, input.exists, input.value as? String == expectedDraft,
                  !app.alerts.firstMatch.exists, !app.sheets.firstMatch.exists,
                  !app.staticTexts["Replace saved configuration?"].exists,
                  !app.collectionViews["File View"].exists,
                  keyboard.exists, keyboard.frame.width > 0, keyboard.frame.height > 0,
                  let window = app.windows.allElementsBoundByIndex.first(where: {
                      $0.exists && $0.frame.width > $0.frame.height
                  }) else {
                XCTFail("Footer scrolling must retain the unchanged editor draft and keyboard without activating an action or confirmation.")
                throw NSError(domain: "Round8EditorFooterScroll", code: 1)
            }
            let top = max(window.frame.minY, editor.frame.maxY) + 4
            var bottom = min(window.frame.maxY, keyboard.frame.minY)
            // The keyboard's key grid excludes its input-assistant toolbar.
            // Use its observed frame too; neither gestures nor button bounds
            // may occupy that toolbar's area.
            for accessory in app.otherElements.matching(identifier: "SystemInputAssistantView").allElementsBoundByIndex
                where accessory.exists && accessory.frame.width > 0 && accessory.frame.height > 0 {
                if accessory.frame.intersects(window.frame) {
                    bottom = min(bottom, accessory.frame.minY)
                }
            }
            let visible = CGRect(x: window.frame.minX, y: top, width: window.frame.width,
                                 height: bottom - 4 - top)
            guard !visible.isNull, !visible.isInfinite, visible.width > 0, visible.height >= 52 else {
                XCTFail("The actual editor must expose enough space for a bounded gutter pan above the keyboard and its toolbar.")
                throw NSError(domain: "Round8EditorFooterScroll", code: 2)
            }
            return visible
        }
        for _ in 0..<24 {
            let visible = try admittedViewport()
            let frame = action.frame
            if frame.width > 0, frame.height >= 44, visible.contains(frame) { break }
            guard footer.allSatisfy({ $0.exists && $0.frame.width > 0 }) else {
                throw NSError(domain: "Round8EditorFooterScroll", code: 3)
            }
            // AX frames do not guarantee native hit-test exclusion. Preserve
            // the gutter input while admitting no action during any pan.
            let leftmostAction = footer.map { $0.frame.minX }.min()!
            let gutterX = max(visible.minX + 4, leftmostAction - 8)
            guard gutterX < leftmostAction, gutterX < visible.maxX - 4 else {
                XCTFail("No sheet gutter exists left of the reported footer frames.")
                throw NSError(domain: "Round8EditorFooterScroll", code: 4)
            }
            let requested = frame.midY - visible.midY
            // Always correct toward the measured center. A forced 44-point
            // move away oscillated across the maximum-text fit interval.
            // Use the common scroll helper's minimum travel; containment and
            // action cancellation remain independent requirements below.
            let distance = min(visible.height - 8, max(16, min(visible.height * 0.4, abs(requested))))
            let direction: CGFloat = requested < 0 ? -1 : 1
            scrollSamples.append("before=\(frame), viewport=\(visible), requested=\(requested), pan=\(direction * distance)")
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: gutterX - app.frame.minX,
                dy: visible.midY + direction * distance / 2 - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: gutterX - app.frame.minX,
                dy: visible.midY - direction * distance / 2 - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 1.0)
            _ = try admittedViewport()
            scrollSamples.append("after=\(action.frame)")
        }
        waitForSettledFrame(action)
        let visible = try admittedViewport()
        XCTAssertTrue(action.frame.width > 0 && action.frame.height >= 44 && visible.contains(action.frame),
                      "The complete footer action must fit above the keyboard and its toolbar. Action=\(action.frame), visible=\(visible).")
    }

    private func scrollFullyIntoView(_ app: XCUIApplication, _ element: XCUIElement, in lane: XCUIElement? = nil, presentedSheet: XCUIElement? = nil, throughGutter: Bool = false, afterScroll: (() -> Void)? = nil) {
        // A heading can be tappable while its illustration is already above the
        // viewport. Move the complete scene using its real frame, with bounded
        // gestures that stay inside the native content viewport.
        func viewport() -> CGRect {
            let header = presentedSheet ?? app.navigationBars.firstMatch
            let top = header.exists ? header.frame.maxY + 8 : app.frame.minY + 8
            // A presented sheet covers the retained page's bottom tab bar.
            // Measure its visible window, rather than that background bar.
            var contentEdge = presentedSheet == nil ? contentBottom(app) : app.frame.maxY
            let keyboard = app.keyboards.firstMatch
            if presentedSheet != nil, keyboard.exists, keyboard.frame.height > 0 {
                contentEdge = min(contentEdge, keyboard.frame.minY)
            }
            let bottom = contentEdge - 8
            let page = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: bottom - top)
            return lane.map { page.intersection($0.frame).insetBy(dx: 0, dy: 4) } ?? page
        }
        // Large text in a short landscape viewport needs many small pans.
        // UIKit consumes part of each gesture before scrolling, so gesture
        // distance cannot predict the count. Stop on actual containment, capped
        // to keep a non-scrolling surface from looping indefinitely.
        if let presentedSheet { XCTAssertTrue(presentedSheet.waitForExistence(timeout: 10)) }
        for _ in 0..<48 {
            let visible = viewport(), frame = element.frame
            if visible.contains(frame) { break }
            // Center a scene that fits instead of chasing a clipped edge;
            // a small edge correction can oscillate across the pan threshold.
            let requested = frame.height <= visible.height
                ? frame.midY - visible.midY
                : (frame.maxY > visible.maxY ? frame.maxY - visible.maxY : frame.minY - visible.minY)
            // Cross UIKit's pan threshold even for a small final adjustment;
            // otherwise a nearly stationary drag can activate a destination row.
            let distance = (requested < 0 ? -1.0 : 1.0) * max(16, min(visible.height * 0.4, abs(requested)))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            // A prose field has its own scroll recognizer. The sheet gutter
            // scrolls the parent without moving the caret or hitting an action.
            // Explore's diagram also owns physical drag inspection; page
            // scrolling must start outside that interactive drawing.
            let gestureX = presentedSheet != nil || throughGutter ? visible.minX + 4 : visible.midX
            let start = origin.withOffset(CGVector(dx: gestureX - app.frame.minX, dy: visible.midY - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: gestureX - app.frame.minX, dy: visible.midY - app.frame.minY - distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 1.0)
            afterScroll?()
        }
        waitForSettledFrame(element)
        XCTAssertTrue(viewport().contains(element.frame), "The complete scene must fit in the capture. Scene=\(element.frame), visible=\(viewport()).")
    }

    private func enterPasscode(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("1234")
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForNonExistence(timeout: 10))
    }
    private func renderedStaticText(_ app: XCUIApplication, _ title: String) throws -> XCUIElement {
        let query = app.staticTexts.matching(identifier: title)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let leaves = query.allElementsBoundByIndex.filter {
            $0.children(matching: .staticText).matching(identifier: title).count == 0
        }
        XCTAssertEqual(leaves.count, 1, "Measure the unique rendered text leaf rather than Fabric's paragraph container.")
        return try XCTUnwrap(leaves.first)
    }
    func testCustomTextSizeChangesReactLayoutAndRestoresSystem() throws {
        let app = launch()
        restoreSystemTextSizeAfterCase = true
        nativeTab(app, "Settings").tap()
        app.buttons["row.Customization"].tap()
        let system = app.switches["Match system"]
        for _ in 0..<4 where !system.isHittable { app.swipeUp() }
        XCTAssertTrue(system.isHittable)
        if system.value as? String == "1" { system.tap() }
        let slider = app.sliders["Text size"]
        for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
        XCTAssertTrue(slider.isHittable, app.debugDescription)
        slider.adjust(toNormalizedSliderPosition: 0)
        // Measure React-rendered prose, not the switch's combined accessibility
        // label (which is not a separate StaticText element).
        let label = app.staticTexts["Change Lava’s look and feel. Protection stays the same."].firstMatch
        for _ in 0..<6 where !label.isHittable { app.swipeDown() }
        waitForSettledFrame(label)
        let small = label.frame.height
        for _ in 0..<6 where !slider.isHittable { app.swipeUp() }
        XCTAssertTrue(slider.isHittable, app.debugDescription)
        slider.adjust(toNormalizedSliderPosition: 1)
        for _ in 0..<6 where !label.isHittable { app.swipeDown() }
        let enlarged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in label.frame.height > small }, object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [enlarged], timeout: 10), .completed)
        XCTAssertGreaterThan(label.frame.height, small)
        capture(app, "React text follows the native custom text size")

        // Visit the real story pages with the maximum native text override. A
        // second Settings tap would pop its stack, so switch tabs only once on
        // return to keep the original Customization controls and restore them.
        nativeTab(app, "Guard").tap()
        XCTAssertTrue(app.navigationBars["Guard"].waitForExistence(timeout: 10), app.debugDescription)
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Protection status")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        waitForSettledFrame(status)
        capture(app, "Large text Guard protection")
        for identifier in ["guard.today", "guard.filter", "guard.explore"] {
            let control = app.buttons[identifier]
            for _ in 0..<8 where !control.isHittable { app.swipeUp() }
            XCTAssertTrue(control.isHittable, "Guard's main destinations must remain reachable with large text: \(identifier).")
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
            if identifier == "guard.filter" { capture(app, "Large text Guard summaries") }
        }
        app.buttons["guard.explore"].tap()
        XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 10), app.debugDescription)
        let exploreContent = app
        XCTAssertTrue(exploreContent.staticTexts["Welcome"].exists)
        XCTAssertFalse(exploreContent.buttons["explore.configure"].exists)
        let playback = exploreContent.buttons["explore.play"]
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        for _ in 0..<8 where !playback.isHittable { app.swipeUp() }
        XCTAssertTrue(playback.isHittable, "The single demo action must remain reachable with large text.")
        XCTAssertGreaterThanOrEqual(playback.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(playback.frame.maxX, app.frame.maxX)
        capture(app, "Large text Explore demo action")
        let phone = exploreContent.buttons["connection.phone"]
        for _ in 0..<6 where !phone.isHittable { app.swipeDown() }
        XCTAssertTrue(phone.isHittable, "The enlarged connection path must remain reachable.")
        capture(app, "Large text Explore connection")
        let filterStep = exploreContent.buttons["connection.filter"]
        for _ in 0..<6 where !filterStep.isHittable { app.swipeUp() }
        XCTAssertTrue(filterStep.isHittable)
        filterStep.tap()
        let configure = exploreContent.buttons["explore.configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 10))
        XCTAssertFalse(exploreContent.staticTexts["Welcome"].exists)
        let exploreScroll = app.scrollViews.containing(.button, identifier: "explore.configure").firstMatch
        XCTAssertTrue(exploreScroll.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "Large text Explore configuration before measured scrolling")
        scrollFullyIntoView(app, configure, in: exploreScroll, throughGutter: true)
        XCTAssertTrue(configure.isHittable, "The connection's real configuration must remain reachable with large text.")
        XCTAssertEqual(configure.label, "Open Filters")
        capture(app, "Large text Explore configuration")
        configure.tap()
        XCTAssertTrue(app.buttons["row.Now filtering"].waitForExistence(timeout: 10), app.debugDescription)
        nativeTab(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Customization"].waitForExistence(timeout: 10), "Returning from Guard must preserve the Settings stack.")
        for _ in 0..<6 where !system.isHittable { app.swipeUp() }
        XCTAssertTrue(system.isHittable, app.debugDescription)
        XCTAssertEqual(system.value as? String, "0", "The app must retain the custom size throughout the story journey.")
        system.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in system.value as? String == "1" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    }

    func testFilterDraftReviewsNonActiveChangesBeforePersistence() throws {
        let app = launch()
        let domain = "rn-qa-" + UUID().uuidString.lowercased() + ".invalid"
        func openCore() {
            app.buttons["guard.filter"].tap()
            app.buttons["row.Switch or manage filters"].tap()
            app.buttons["Core"].tap()
            let viewOnly = app.buttons["View or edit only"]
            XCTAssertTrue(viewOnly.waitForExistence(timeout: 10))
            waitForSettledFrame(viewOnly)
            viewOnly.tap()
            XCTAssertTrue(viewOnly.waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "filter.identity.name", "Core")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        }
        openCore()
        app.navigationBars.buttons["Edit"].tap()
        let add = app.buttons["Block a domain"]
        for _ in 0..<5 where !add.isHittable { app.swipeUp() }
        add.tap()
        XCTAssertTrue(app.buttons["Add domain"].waitForExistence(timeout: 10))
        let field = app.textFields["Domain to block"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        waitForSettledFrame(field)
        let domainHeader = app.navigationBars.firstMatch
        XCTAssertGreaterThanOrEqual(field.frame.minY, domainHeader.frame.maxY,
                                   "Autofocus must not push the domain row behind its header.")
        let focusedY = field.frame.minY
        app.typeText(domain)
        XCTAssertEqual(field.frame.minY, focusedY, accuracy: 2)
        capture(app, "Domain sheet keyboard preserves the input below its native header")
        app.buttons["Add domain"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "filter.identity.name", "Core")).firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons["Save"].tap()
        let confirmation = app.buttons["Confirm changes"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10), app.debugDescription)
        confirmation.tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Confirm changes"].exists)
        capture(app, "Inactive native filter saved directly from React Native")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "filter.identity.name", "Core")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()
        app.launch()
        openCore()
        app.navigationBars.buttons["Edit"].tap()
        let remove = app.buttons["filter.edit." + domain]
        for _ in 0..<5 where !remove.isHittable { app.swipeUp() }
        XCTAssertTrue(remove.isHittable, "The saved native filter must survive an RN relaunch.")
        capture(app, "Native filter edit survived relaunch")
        remove.tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10), app.debugDescription)
        confirmation.tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Confirm changes"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "filter.identity.name", "Core")).firstMatch.waitForExistence(timeout: 10))
    }
    func testLibraryChoiceUsesNativeDialogAndOutsideCancellation() throws {
        let app = launch()
        app.buttons["guard.filter"].tap()
        app.buttons["row.Switch or manage filters"].tap()
        app.buttons["Core"].tap()
        let switchAction = app.buttons["Switch to this filter"]
        XCTAssertTrue(switchAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["View or edit only"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertTrue(app.sheets.firstMatch.exists, "Filter actions must remain a system dialog.")
        XCTAssertLessThan(app.sheets.firstMatch.frame.height, app.frame.height * 0.5,
                          "The compact action dialog must not regress into a large presentation sheet.")
        capture(app, "Native filter action choices with explicit cancellation")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.17)).tap()
        XCTAssertTrue(switchAction.waitForNonExistence(timeout: 10), "Tapping outside cancels the native choice dialog.")
        XCTAssertTrue(app.buttons["Core"].exists)
        app.buttons["Core"].tap()
        let cancelAction = app.buttons["Cancel"]
        XCTAssertTrue(cancelAction.waitForExistence(timeout: 10), app.debugDescription)
        cancelAction.tap()
        XCTAssertTrue(switchAction.waitForNonExistence(timeout: 10), "Explicit Cancel must complete the same native cancellation path.")
        XCTAssertTrue(app.buttons["Core"].exists)
        app.buttons["Core"].tap()
        XCTAssertTrue(switchAction.waitForExistence(timeout: 10), "Either cancellation path must release the dialog's pending command for reopening.")
        let viewOnly = app.buttons["View or edit only"]
        XCTAssertTrue(viewOnly.waitForExistence(timeout: 10))
        waitForSettledFrame(viewOnly)
        viewOnly.tap()
        XCTAssertTrue(viewOnly.waitForNonExistence(timeout: 10))
        let identity = app.staticTexts["filter.identity.name"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let originalY = identity.frame.minY
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "filter.rule.")).allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(rows.isEmpty, "The geometry check must include actual rules, not only the title.")
        let frames = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0.frame) })
        app.navigationBars.buttons["Edit"].tap()
        for row in rows {
            let before = frames[row.identifier]!
            XCTAssertEqual(row.frame.minX, before.minX, accuracy: 1)
            XCTAssertEqual(row.frame.minY, before.minY, accuracy: 1)
            XCTAssertEqual(row.frame.width, before.width, accuracy: 1)
            XCTAssertEqual(row.frame.height, before.height, accuracy: 1)
        }
        XCTAssertEqual(identity.frame.minY, originalY, accuracy: 1.5, "Edit controls cannot move the identity panel.")
        capture(app, "Filter view and edit retain identity geometry")
        app.navigationBars.buttons["Cancel editing"].tap()
    }

    func testCatalogHeadersAndCustomEntryClosePreservePickerDraft() throws {
        let app = launch(paidPlan: true)
        // Reuse the existing optional capture fixture to select the real
        // persisted appearance. Ordinary CI keeps its current launch behavior.
        if let appearance = ProcessInfo.processInfo.environment["LAVA_UI_TEST_FEEDBACK_APPEARANCE"] {
            XCTAssertTrue(["Light", "Dark"].contains(appearance))
            guard ["Light", "Dark"].contains(appearance) else { return }
            nativeTab(app, "Settings").tap()
            let customization = app.buttons["row.Customization"]
            scrollFullyIntoView(app, customization)
            customization.tap()
            XCTAssertTrue(app.navigationBars["Customization"].waitForExistence(timeout: 10))
            let theme = app.segmentedControls["Appearance"].buttons[appearance]
            scrollFullyIntoView(app, theme)
            waitForSettledFrame(theme)
            theme.tap()
            XCTAssertTrue(theme.isSelected)
            capture(app, "Catalog capture selects persisted \(appearance) appearance")
            nativeBack(app).tap()
            nativeTab(app, "Guard").tap()
        }
        let filterEntry = app.buttons["guard.filter"]
        XCTAssertTrue(filterEntry.waitForExistence(timeout: 10))
        waitForSettledFrame(filterEntry)
        filterEntry.tap()
        if #available(iOS 26.0, *) {
            let libraryEntry = app.buttons["row.Switch or manage filters"]
            XCTAssertTrue(libraryEntry.waitForExistence(timeout: 10))
            libraryEntry.tap()
            app.buttons["Core"].tap()
            let viewOnly = app.buttons["View or edit only"]
            XCTAssertTrue(viewOnly.waitForExistence(timeout: 10))
            // UIKit may expose an action before its popover stops moving.
            // A tap on that transitional frame leaves the choice open.
            waitForSettledFrame(viewOnly)
            viewOnly.tap()
            XCTAssertTrue(viewOnly.waitForNonExistence(timeout: 10), "Selecting the settled native action must close the choice sheet.")
        } else {
            let current = app.buttons["row.Now filtering"]
            XCTAssertTrue(current.waitForExistence(timeout: 10))
            current.tap()
        }
        // iOS 18 reaches the same picker from the current filter's editor.
        // Its existing filter-choice alert rejects a presentation delegate.
        // Library also has an Edit toolbar item while filter.open resolves;
        // require the destination identity before interacting with detail.
        XCTAssertTrue(app.staticTexts["filter.identity.name"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Edit"].tap()
        let addList = app.buttons["Add a blocklist"]
        XCTAssertTrue(addList.waitForExistence(timeout: 10), app.debugDescription)
        scrollFullyIntoView(app, addList)
        addList.tap()
        let listSearch = app.textFields["Search blocklists or categories"]
        XCTAssertTrue(listSearch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["Close"].isHittable)
        let listHeader = fullSheetHeader(app, title: "Choose blocklists")
        let listScroll = app.otherElements["sheet.results"].scrollViews.firstMatch
        XCTAssertTrue(listScroll.waitForExistence(timeout: 10))
        waitForSettledFrame(listHeader)
        XCTAssertGreaterThanOrEqual(listScroll.frame.minY, listHeader.frame.maxY)
        XCTAssertLessThan(listScroll.frame.minY, listHeader.frame.maxY + 20)
        XCTAssertLessThan(listSearch.frame.minY, listHeader.frame.maxY + 100,
                          "The category/search controls must start immediately below the native bar.")
        let pinnedY = listSearch.frame.minY
        let firstList = listScroll.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Block List Basic")).firstMatch
        XCTAssertTrue(firstList.waitForExistence(timeout: 10))
        let firstListY = firstList.frame.minY
        listScroll.swipeDown()
        waitForSettledFrame(listSearch)
        XCTAssertEqual(listSearch.frame.minY, pinnedY, accuracy: 2,
                       "Pulling a newly opened catalog must not leave a gap above its controls.")
        listScroll.swipeUp()
        XCTAssertEqual(listSearch.frame.minY, pinnedY, accuracy: 2,
                       "Picker search stays pinned while list content moves beneath its material.")
        XCTAssertLessThan(firstList.frame.minY, firstListY - 20)
        capture(app, "Blocklist picker glass capsules over scrolling rows")
        app.buttons["Multi-purpose"].tap()
        let category = listScroll.staticTexts["Multi-purpose"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        waitForSettledFrame(category)
        XCTAssertGreaterThanOrEqual(category.frame.minY, listSearch.frame.maxY)
        XCTAssertLessThan(category.frame.minY, listSearch.frame.maxY + 60,
                          "Category jumps must reveal their heading below the pinned controls.")
        capture(app, "Blocklist picker native header and pinned controls")
        let listSearchFrame = listSearch.frame
        let listCategory = app.buttons["Multi-purpose"]
        let listCategoryFrame = listCategory.frame
        let noMatchQuery = "lava-catalog-no-match-rc17"
        listSearch.tap(); listSearch.typeText(noMatchQuery)
        let emptyCatalog = app.staticTexts["No blocklists found"].firstMatch
        XCTAssertTrue(emptyCatalog.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        waitForSettledFrame(listSearch)
        XCTAssertEqual(listSearch.value as? String, noMatchQuery)
        XCTAssertGreaterThanOrEqual(emptyCatalog.frame.minY, listSearch.frame.maxY,
                                   "Empty search feedback must be visible below the controls, not behind the native bar.")
        XCTAssertEqual(listSearch.frame.minY, pinnedY, accuracy: 2,
                       "An empty result with the keyboard must retain the pinned search position.")
        XCTAssertEqual(listSearch.frame.width, listSearchFrame.width, accuracy: 2)
        XCTAssertEqual(listSearch.frame.height, listSearchFrame.height, accuracy: 2)
        XCTAssertTrue(listCategory.exists, "Searching must retain the unfiltered category controls.")
        XCTAssertEqual(listCategory.frame.minY, listCategoryFrame.minY, accuracy: 2)
        XCTAssertEqual(listCategory.frame.width, listCategoryFrame.width, accuracy: 2)
        XCTAssertEqual(listCategory.frame.height, listCategoryFrame.height, accuracy: 2)
        retainFrames(["searchBefore": listSearchFrame, "searchEmpty": listSearch.frame,
                      "categoryBefore": listCategoryFrame, "categoryEmpty": listCategory.frame],
                     name: "Catalog keyboard empty-result control frames")
        capture(app, "Blocklist picker glass search with keyboard and empty results")
        let emptyCatalogY = emptyCatalog.frame.minY
        for _ in 0..<3 {
            listScroll.swipeUp()
            waitForSettledFrame(emptyCatalog)
            XCTAssertEqual(emptyCatalog.frame.minY, emptyCatalogY, accuracy: 2,
                           "An empty catalog must have no artificial scroll range above the keyboard.")
            XCTAssertEqual(listSearch.frame.minY, pinnedY, accuracy: 2)
        }
        listSearch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: noMatchQuery.count))
        XCTAssertTrue(emptyCatalog.waitForNonExistence(timeout: 10))
        XCTAssertTrue(firstList.waitForExistence(timeout: 10))
        listSearch.typeText("HaGeZi")
        app.navigationBars.buttons["Add your own blocklist"].tap()
        XCTAssertTrue(app.otherElements["custom-entry-page"].waitForExistence(timeout: 10), app.debugDescription)
        let listClose = app.navigationBars["Add your own blocklist"].buttons["Close"]
        XCTAssertTrue(listClose.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "Custom blocklists must use the shared Close action after the native transition.")
        capture(app, "Custom blocklist scaffold Close")
        listClose.tap()
        XCTAssertTrue(listSearch.waitForExistence(timeout: 10))
        XCTAssertEqual(listSearch.value as? String, "HaGeZi", "Closing custom entry must retain the picker draft and search.")
        app.navigationBars.buttons["Close"].tap()
        app.navigationBars.buttons["Cancel editing"].tap()

        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings/dns-resolver")!)
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons["Edit"].tap()
        let deviceDNS = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Device DNS")).firstMatch
        XCTAssertTrue(deviceDNS.waitForExistence(timeout: 10), app.debugDescription)
        deviceDNS.tap()
        let dnsSearch = app.textFields["Search DNS providers or transports"]
        XCTAssertTrue(dnsSearch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["Close"].isHittable)
        let dnsHeader = fullSheetHeader(app, title: "Choose DNS")
        let dnsScroll = app.otherElements["sheet.results"].scrollViews.firstMatch
        XCTAssertTrue(dnsScroll.waitForExistence(timeout: 10))
        waitForSettledFrame(dnsHeader)
        XCTAssertGreaterThanOrEqual(dnsScroll.frame.minY, dnsHeader.frame.maxY)
        XCTAssertLessThan(dnsScroll.frame.minY, dnsHeader.frame.maxY + 20)
        XCTAssertLessThan(dnsSearch.frame.minY, dnsHeader.frame.maxY + 100)
        capture(app, "DNS picker native header and pinned controls")
        let dnsPinnedY = dnsSearch.frame.minY
        dnsScroll.swipeDown()
        waitForSettledFrame(dnsSearch)
        XCTAssertEqual(dnsSearch.frame.minY, dnsPinnedY, accuracy: 2)
        dnsScroll.swipeUp()
        waitForSettledFrame(dnsSearch)
        XCTAssertEqual(dnsSearch.frame.minY, dnsPinnedY, accuracy: 2,
                       "DNS search stays pinned while provider rows move beneath its glass capsule.")
        capture(app, "DNS picker glass capsules over scrolling provider rows")
        dnsSearch.tap(); dnsSearch.typeText("u")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Quad9")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "HaGeZi DNS")).firstMatch.exists,
                       "The u in /dns-query must not match an unrelated provider.")
        dnsSearch.typeText("u")
        let emptyDNS = app.staticTexts["No DNS providers found"].firstMatch
        XCTAssertTrue(emptyDNS.waitForExistence(timeout: 10))
        waitForSettledFrame(emptyDNS)
        let emptyDNSY = emptyDNS.frame.minY
        for _ in 0..<3 {
            dnsScroll.swipeUp()
            waitForSettledFrame(emptyDNS)
            XCTAssertEqual(emptyDNS.frame.minY, emptyDNSY, accuracy: 2)
            XCTAssertEqual(dnsSearch.frame.minY, dnsPinnedY, accuracy: 2)
        }
        capture(app, "DNS empty results remain below pinned controls with keyboard")
        dnsSearch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        dnsSearch.typeText("Cloudflare")
        XCTAssertEqual(dnsSearch.value as? String, "Cloudflare", "Typing must finish before opening custom entry.")
        app.navigationBars.buttons["Add custom DNS"].tap()
        XCTAssertTrue(app.otherElements["custom-entry-page"].waitForExistence(timeout: 10), app.debugDescription)
        let dnsClose = app.navigationBars["Custom DNS"].buttons["Close"]
        XCTAssertTrue(dnsClose.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "Custom DNS must use the shared Close action after the native transition.")
        capture(app, "Custom DNS scaffold Close")
        dnsClose.tap()
        XCTAssertTrue(dnsSearch.waitForExistence(timeout: 10))
        XCTAssertEqual(dnsSearch.value as? String, "Cloudflare")
        app.navigationBars.buttons["Close"].tap()
        app.navigationBars.buttons["Cancel editing"].tap()
    }

    func testNewFilterIsADraftUntilSaveAndCancelCreatesNothing() throws {
        let app = launch()
        func openLibrary() {
            app.buttons["guard.filter"].tap()
            app.buttons["row.Switch or manage filters"].tap()
            XCTAssertTrue(app.navigationBars["Your filters"].waitForExistence(timeout: 10))
        }
        func savedRows() -> XCUIElementQuery {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "filter.library."))
        }
        func restoreDefaults() {
            app.navigationBars.buttons["Edit"].tap()
            let restore = app.buttons["Restore default filters"]
            scrollFullyIntoView(app, restore)
            restore.tap()
            app.alerts.buttons["Restore"].tap()
            XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
            XCTAssertEqual(savedRows().count, 3)
        }
        func createDraft() {
            app.navigationBars.buttons["Edit"].tap()
            let add = app.buttons["Add a filter"]
            scrollFullyIntoView(app, add)
            add.tap()
            XCTAssertTrue(app.navigationBars["New filter"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.textFields["Filter name"].exists, "Naming belongs to the new draft's existing identity editor.")
            XCTAssertTrue(app.navigationBars.buttons["Close"].exists)
            let template = app.scrollViews.containing(.button, identifier: "Create new").element
            XCTAssertTrue(template.waitForExistence(timeout: 10))
            XCTAssertTrue(template.buttons["Create new"].isSelected)
            template.buttons["Core"].tap()
            XCTAssertFalse(template.buttons["Create new"].isSelected)
            XCTAssertTrue(template.buttons["Core"].isSelected)
            app.buttons["Create"].tap()
            XCTAssertTrue(app.staticTexts["filter.identity.name"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts["filter.identity.name"].label, "Untitled 1")
            XCTAssertTrue(app.navigationBars.buttons["Cancel editing"].exists)
            XCTAssertTrue(app.navigationBars.buttons["Save"].isEnabled)
        }
        openLibrary()
        restoreDefaults()
        app.navigationBars.buttons["Edit"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Delete", "Extra")).element.tap()
        app.navigationBars.buttons["Review changes"].tap()
        XCTAssertTrue(app.buttons["Confirm changes"].waitForExistence(timeout: 10))
        app.buttons["Confirm changes"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertEqual(savedRows().count, 2)
        createDraft()
        capture(app, "New filter template opens an unsaved editable identity")
        app.navigationBars.buttons["Cancel editing"].tap()
        XCTAssertTrue(app.navigationBars["Your filters"].waitForExistence(timeout: 10))
        XCTAssertEqual(savedRows().count, 2, "Cancelling must not leave a library placeholder.")
        XCTAssertFalse(app.buttons["Untitled 1"].exists)
        createDraft()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        nativeBack(app).tap()
        XCTAssertEqual(savedRows().count, 3)
        XCTAssertTrue(app.buttons["Untitled 1"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["guard.filter"].waitForExistence(timeout: 20))
        openLibrary()
        XCTAssertEqual(savedRows().count, 3, "Only the confirmed new filter survives relaunch.")
        XCTAssertTrue(app.buttons["Untitled 1"].exists)
        capture(app, "Confirmed new filter survives relaunch in the saved library")
        restoreDefaults()
    }

    func testDNSCompoundControlsAndNativeTransportPreserveSavedSettings() throws {
        let app = launch(paidPlan: true)
        nativeTab(app, "Settings").tap()
        let entry = app.buttons["connection.dns"]
        scrollFullyIntoView(app, entry); entry.tap()
        let header = app.navigationBars["DNS settings"]
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        let device = app.switches["Device DNS"]
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        let enabledTiers = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dns.tier-toggle."))
            .allElementsBoundByIndex.filter { $0.switches.firstMatch.value as? String == "1" }.count
        XCTAssertGreaterThan(enabledTiers, 0, "The real saved DNS configuration must retain an enabled tier.")
        // Fresh onboarding enables an encrypted fallback; a saved configuration
        // can contain only Device DNS. Qualify the same switch invariant against
        // actual readback without changing native defaults for this journey.
        XCTAssertEqual(device.isEnabled, enabledTiers > 1,
                       "The sole enabled DNS tier cannot be switched off; another enabled tier permits toggling.")
        XCTAssertTrue(header.buttons["Edit"].isEnabled, "The unchained tier still admits selection editing.")
        let savedValue = try XCTUnwrap(device.value as? String)
        XCTAssertEqual(savedValue, "1", "Use the isolated simulator's initial Device DNS tier.")
        header.buttons["Edit"].tap()
        let tier = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Device DNS")).firstMatch
        XCTAssertTrue(tier.waitForExistence(timeout: 10)); tier.tap()
        let search = app.textFields["Search DNS providers or transports"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        waitForSettledFrame(search); search.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: search)], timeout: 10), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        waitForSettledFrame(app.keyboards.firstMatch, requiresHittable: false)
        search.typeText("Cloudflare")
        XCTAssertEqual(search.value as? String, "Cloudflare")
        let picker = app.scrollViews.containing(.textField, identifier: "Search DNS providers or transports").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let encrypted = picker.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND value CONTAINS %@", "Cloudflare", "https://cloudflare-dns.com/dns-query")).firstMatch
        XCTAssertTrue(encrypted.waitForExistence(timeout: 10), app.debugDescription)
        scrollFullyIntoView(app, encrypted)
        XCTAssertTrue(encrypted.isHittable, "The current tier picker must expose the actual DoH endpoint.")
        encrypted.tap()
        capture(app, "DNS tier picker reviews a native-catalog DoH transport")
        // This existing native-hosted picker pins its footer below search.
        // Finish editing with the keyboard's normal Return/Done action before
        // confirming; scrolling cannot move an independently pinned footer.
        if app.keyboards.firstMatch.exists { search.typeText("\n") }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "Cloudflare")
        let selection = app.buttons["Save selection"]
        scrollFullyIntoView(app, selection, presentedSheet: app.navigationBars["Choose DNS"]); selection.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let staged = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND value CONTAINS %@", "Cloudflare", "DoH")).firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: 10), "Picker confirmation stages the transport in the unsaved tier draft.")
        capture(app, "DNS compound tier row retains the staged transport metadata")
        header.buttons["Cancel editing"].tap()
        let discard = app.alerts["Discard changes?"].buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10)); discard.tap()
        XCTAssertTrue(header.buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertEqual(device.value as? String, savedValue, "Discard must preserve the saved DNS tier and its enabled state.")
        XCTAssertFalse(staged.exists)
        nativeBack(app).tap(); entry.tap()
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        XCTAssertEqual(device.value as? String, savedValue, "Reentry must read the unchanged native DNS configuration.")
    }

    func testConfirmationGlyphsRemainWhiteInBothNativeToolbarHosts() throws {
        let app = launch()
        func assertWhiteGlyph(_ button: XCUIElement, name: String) {
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            waitForSettledFrame(button)
            XCTAssertTrue(button.isEnabled)
            capture(app, name)
            let image = app.screenshot().image.cgImage!
            let scale = CGFloat(image.width) / app.frame.width
            let frame = button.frame
            let crop = CGRect(x: (frame.midX - 12) * scale, y: (frame.midY - 12) * scale,
                              width: 24 * scale, height: 24 * scale)
            let glyph = image.cropping(to: crop)!
            var pixels = [UInt8](repeating: 0, count: 40 * 40 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 40, height: 40,
                    bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(glyph, in: CGRect(x: 0, y: 0, width: 40, height: 40))
            }
            let white = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 230 && pixels[$0 + 1] > 230 && pixels[$0 + 2] > 230
            }.count
            XCTAssertGreaterThan(white, 5, "The inner glyph must be white, not the native automatic black contrast.")
        }
        app.buttons["guard.filter"].tap()
        app.buttons["row.Switch or manage filters"].tap()
        app.navigationBars.buttons["Edit"].tap()
        app.buttons.matching(NSPredicate(format: "label == 'Delete' AND value == 'Core'")).firstMatch.tap()
        assertWhiteGlyph(app.navigationBars.buttons["Review changes"], name: "RN native toolbar white confirmation")
        app.buttons.matching(NSPredicate(format: "label == 'Undo' AND value == 'Core'")).firstMatch.tap()
        app.buttons["Core"].tap()
        XCTAssertTrue(app.navigationBars["Rename filter"].waitForExistence(timeout: 10))
        assertWhiteGlyph(app.buttons["Save"], name: "Foreground modal native toolbar white confirmation")
        app.buttons["Cancel"].tap()
    }

    func testLibraryStagingAndNativeRenamePreserveCancellationAndPersistence() throws {
        let app = launch()
        func openLibrary() {
            app.buttons["guard.filter"].tap()
            app.buttons["row.Switch or manage filters"].tap()
            XCTAssertTrue(app.buttons["Core"].waitForExistence(timeout: 10), app.debugDescription)
        }
        openLibrary()
        let baseline = libraryFrames(app)
        retainFrames(baseline, name: "Library before repeated Edit")
        for cycle in 0..<2 {
            app.navigationBars.buttons["Edit"].tap()
            XCTAssertTrue(app.navigationBars.buttons["Close edit mode"].waitForExistence(timeout: 10))
            assertSameFrames(libraryFrames(app), baseline, phase: "Library clean Edit cycle \(cycle)")
            XCTAssertFalse(app.navigationBars.buttons["Review changes"].isEnabled)
            app.navigationBars.buttons["Close edit mode"].tap()
            XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
            assertSameFrames(libraryFrames(app), baseline, phase: "Library viewing cycle \(cycle)")
        }
        app.navigationBars.buttons["Edit"].tap()
        let deletion = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND value == 'Core'")).firstMatch
        XCTAssertTrue(deletion.waitForExistence(timeout: 10), app.debugDescription)
        recordControlBounds(app, ["RN library Close": app.navigationBars.buttons["Close edit mode"],
                                 "RN inline Delete Core": deletion], phase: "Library edit controls")
        deletion.tap()
        assertSameFrames(libraryFrames(app), baseline, phase: "Library staged deletion")
        recordControlBounds(app, ["RN enabled confirm": app.navigationBars.buttons["Review changes"]], phase: "Library valid review toolbar")
        app.navigationBars.buttons["Review changes"].tap()
        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons["Cancel"].tap()
        let undo = app.buttons.matching(NSPredicate(format: "label == 'Undo' AND value == 'Core'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "Cancelling the confirmation must retain the staged deletion.")
        assertSameFrames(libraryFrames(app), baseline, phase: "Library review cancellation return")
        capture(app, "Library settled rows after staged deletion and review return")
        undo.tap()
        XCTAssertTrue(app.buttons["filter.library.filter-essential"].waitForExistence(timeout: 10))
        capture(app, "Library Edit exposes the accessible filter identity action")
        app.buttons["filter.library.filter-essential"].tap()
        XCTAssertTrue(app.navigationBars["Rename filter"].waitForExistence(timeout: 10), app.debugDescription)
        let field = app.textFields["Filter name"]
        func replaceName(_ name: String) {
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + name)
        }
        replaceName("Balanced")
        XCTAssertTrue(app.staticTexts["You already have a filter with that name."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        replaceName("Name!")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        replaceName("RN Contract Core")
        let emoji = app.textFields["filter.identity.emoji.input"]
        XCTAssertTrue(emoji.exists)
        let originalEmoji = emoji.value as? String ?? "🌱"
        func replaceEmoji(_ value: String) {
            // Editing the name can expand the native sheet as its keyboard
            // arrives. Resolve a settled, hittable field before synthesizing
            // the next touch; a frame from the earlier detent is stale.
            waitForSettledFrame(emoji)
            emoji.tap()
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: emoji)
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed,
                           "The native emoji leaf must receive keyboard focus.")
            emoji.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (emoji.value as? String ?? "").count) + value)
        }
        capture(app, "Rename inputs use equal control slots and a shared divider")
        // Accessibility groups union their descendants: UIKit reports the whole
        // emoji field, while SwiftUI reports only its text's ink. Compare their
        // centers relative to the row label, not these different ink bounds.
        func leafLabel(_ title: String) -> XCUIElement {
            let explicit = app.staticTexts["filter.identity.\(title.lowercased()).label"].firstMatch
            if explicit.exists { return explicit }
            let row = app.otherElements["filter.identity.\(title.lowercased()).row"]
            XCTAssertTrue(row.exists, app.debugDescription)
            return row.staticTexts.matching(identifier: title).allElementsBoundByIndex.first {
                $0.children(matching: .staticText).matching(identifier: title).count == 0
            } ?? row.staticTexts[title].firstMatch
        }
        XCTAssertEqual(emoji.frame.midY - leafLabel("Emoji").frame.midY,
                       field.frame.midY - leafLabel("Name").frame.midY, accuracy: 1.5)
        XCTAssertLessThan(emoji.frame.midY, field.frame.midY)
        replaceEmoji("🍐🍊")
        XCTAssertEqual(emoji.value as? String, "🍊", "A new complete emoji replaces the prior glyph during input.")
        XCTAssertFalse(app.staticTexts["Choose one emoji."].exists)
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        replaceEmoji("🍐")
        capture(app, "Native emoji keyboard and one-emoji identity editor")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["filter.library.filter-essential"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons["filter.library.filter-essential"].label, "RN Contract Core")
        app.navigationBars.buttons["Review changes"].tap()
        XCTAssertTrue(app.buttons["Confirm changes"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Confirm changes"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "Library preserves cancellation and commits rename only after review")
        app.terminate()
        app.launch()
        app.buttons["guard.filter"].tap()
        app.buttons["row.Switch or manage filters"].tap()
        XCTAssertTrue(app.buttons["RN Contract Core"].waitForExistence(timeout: 10), "Native rename must survive relaunch.")
        app.navigationBars.buttons["Edit"].tap()
        app.buttons["RN Contract Core"].tap()
        XCTAssertEqual(emoji.value as? String, "🍐", "Emoji persists with the name across relaunch.")
        replaceEmoji(originalEmoji)
        replaceName("Core")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["filter.library.filter-essential"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Review changes"].tap()
        XCTAssertTrue(app.buttons["Confirm changes"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Confirm changes"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testNativeAutomationAndImportFlowsPresentAboveReact() throws {
        let app = launch()
        app.buttons["guard.filter"].tap()
        app.buttons["row.Auto-switch filters"].tap()
        XCTAssertTrue(app.navigationBars["Auto-switch filters"].waitForExistence(timeout: 10), app.debugDescription)
        let back = nativeBack(app)
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(back.frame.width, 44, accuracy: 0.5)
        XCTAssertFalse(app.navigationBars["Auto-switch filters"].buttons["Close"].exists)
        capture(app, "Native Shortcuts and Focus automation as an ordinary pushed page")
        back.tap()
        // Auto-switch opens from Filters itself, so Back returns directly to
        // its Import action without an extra library pop or modal dismissal.
        let importFilter = app.navigationBars["Filters"].buttons["Import"]
        XCTAssertTrue(importFilter.waitForExistence(timeout: 10), app.debugDescription)
        importFilter.tap()
        XCTAssertTrue(app.buttons["Enter a code"].waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "Native shared filter import from React Native")
        app.buttons["Enter a code"].tap()
        let codeHeader = fullSheetHeader(app, title: "Enter a code")
        XCTAssertTrue(codeHeader.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.textViews.firstMatch.exists)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
    }

    func testDomainHistoryEnablesNativeLoggingAndPersistsAcrossRelaunch() throws {
        let app = launch()
        func privacy() {
            XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings")!)
            let row = app.buttons["row.Privacy & data"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<4 where !row.isHittable { app.swipeUp() }
            row.tap()
            XCTAssertTrue(app.switches["Domain history"].waitForExistence(timeout: 10))
        }
        func disableHistory() {
            app.switches["Domain history"].tap()
            let confirm = app.alerts.buttons["Turn off and clear history"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
            confirm.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: app.switches["Domain history"])], timeout: 5), .completed)
        }
        privacy()
        let wasEnabled = app.switches["Domain history"].value as? String == "1"
        if wasEnabled { disableHistory() }
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://guard")!)
        let activity = app.buttons["guard.today"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        let history = app.buttons["row.Domain History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        for _ in 0..<4 where !history.isHittable { app.swipeUp() }
        history.tap()
        let enable = app.buttons["Turn on domain history"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "Domain History native opt-in while local history is off")
        enable.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: enable)], timeout: 10), .completed)
        app.terminate()
        app.launch()
        privacy()
        XCTAssertEqual(app.switches["Domain history"].value as? String, "1", "History opt-in must persist through the native settings owner.")
        capture(app, "Domain History opt-in persisted into native Privacy settings")
        if !wasEnabled { disableHistory() }
    }


    func testSettingsFeedbackSheetAndDeviceQAPushWithGuardedCloseAndReentry() throws {
        let app = launch()
        nativeTab(app, "Settings").tap()
        // Matched native/RN captures choose the real persisted setting through
        // UIKit. The optional runner fixture leaves the ordinary CI case intact.
        if let appearance = ProcessInfo.processInfo.environment["LAVA_UI_TEST_FEEDBACK_APPEARANCE"] {
            XCTAssertTrue(["Light", "Dark"].contains(appearance))
            guard ["Light", "Dark"].contains(appearance) else { return }
            let customization = app.buttons["row.Customization"]
            scrollFullyIntoView(app, customization)
            customization.tap()
            XCTAssertTrue(app.navigationBars["Customization"].waitForExistence(timeout: 10))
            let theme = app.segmentedControls["Appearance"].buttons[appearance]
            scrollFullyIntoView(app, theme)
            waitForSettledFrame(theme)
            theme.tap()
            XCTAssertTrue(theme.isSelected)
            capture(app, "Feedback capture selects persisted \(appearance) appearance")
            nativeBack(app).tap()
            XCTAssertTrue(app.buttons["row.Feedback"].waitForExistence(timeout: 10))
        }
        let feedbackRow = app.buttons["row.Feedback"]
        scrollFullyIntoView(app, feedbackRow)
        waitForSettledFrame(feedbackRow)
        XCTAssertTrue(feedbackRow.isHittable, app.debugDescription)
        feedbackRow.tap()
        let feedback = fullSheetHeader(app, title: "Feedback")
        XCTAssertTrue(feedback.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.otherElements["feedback-settings-page"].exists)
        XCTAssertFalse(app.tabBars.buttons["Settings"].isHittable, "Settings Feedback covers the tabs as a sheet.")
        let close = feedback.buttons["Cancel"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
        capture(app, "Settings Feedback sheet has a leading Close glyph")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Resume must restore the actual foreground application before inspecting its sheet.")
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let topic = app.buttons["I have a suggestion"]
        for _ in 0..<4 where !topic.isHittable { app.swipeUp() }
        topic.tap()
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10)); next.tap()
        let details = app.textViews.firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        waitForSettledFrame(details); details.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: details)], timeout: 10), .completed)
        let feedbackContent = app.scrollViews.containing(.textView, identifier: nil).firstMatch
        XCTAssertTrue(feedbackContent.waitForExistence(timeout: 10))
        let previewDraft = "Preview retains this draft\nParagraph spacing after Back\nFinal retained line"
        details.typeText(previewDraft)
        capture(app, "Feedback multiline draft before focused preview")
        let previewTitle = "See what information is sent"
        let previewLink = app.links[previewTitle].exists ? app.links[previewTitle] : app.buttons[previewTitle]
        XCTAssertTrue(previewLink.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, previewLink, in: feedbackContent, presentedSheet: feedback)
        XCTAssertTrue(NSPredicate(format: "hasKeyboardFocus == true").evaluate(with: details), "Preview must exercise the still-focused editor transition.")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        previewLink.tap()
        let information = fullSheetHeader(app, title: "Information sent")
        XCTAssertTrue(information.waitForExistence(timeout: 15))
        XCTAssertTrue(details.waitForNonExistence(timeout: 10), "The preview removes its editor from the visible accessibility tree.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "Commit the focused editor before presenting diagnostics.")
        capture(app, "Feedback diagnostics preview after focused draft")
        let lifecycleNote = app.staticTexts["Lifecycle entries use safe event names and counters. Recent DNS and domain events are not included."].firstMatch
        XCTAssertTrue(lifecycleNote.waitForExistence(timeout: 10))
        let previewContent = app.scrollViews.containing(.staticText, identifier: "Lifecycle entries use safe event names and counters. Recent DNS and domain events are not included.").firstMatch
        XCTAssertTrue(previewContent.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, lifecycleNote, in: previewContent, presentedSheet: information)
        XCTAssertTrue(app.staticTexts["enable-begin, enable-finished, reconnect-requested"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["startTunnel-ready, network-path-changed, resolver-reset"].firstMatch.exists)
        capture(app, "Feedback diagnostics lifecycle examples and safe-data footer")
        let previewBack = information.buttons.firstMatch
        XCTAssertTrue(previewBack.wait(for: \.isHittable, toEqual: true, timeout: 10))
        previewBack.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        XCTAssertEqual(details.value as? String, previewDraft, "Preview Back retains the exact committed draft.")
        scrollFullyIntoView(app, details, in: feedbackContent, presentedSheet: feedback)
        capture(app, "Feedback multiline draft after preview Back")
        // Start the limit check with a fresh native owner. Tapping a restored
        // TextEditor can place its caret at the beginning, so backspacing is not
        // a reliable way to clear it. This also qualifies discard after preview.
        close.tap()
        let previewDiscard = app.alerts["Discard feedback?"]
        XCTAssertTrue(previewDiscard.waitForExistence(timeout: 10))
        previewDiscard.buttons["Discard"].tap()
        XCTAssertTrue(feedbackRow.waitForExistence(timeout: 10))
        feedbackRow.tap()
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, topic, presentedSheet: feedback)
        topic.tap()
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 10)); next.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        waitForSettledFrame(details); details.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: details)], timeout: 10), .completed)
        XCTAssertEqual(details.value as? String, "")
        capture(app, "Feedback empty details with native keyboard")
        // Synthetic text exercises the real native limit without submitting a
        // report or using the user's clipboard. One uninterrupted typing burst
        // must settle to exactly the same value as the native draft/counter.
        let limited = String(repeating: "a", count: 5000)
        details.typeText(limited + "b")
        let acceptedLimit = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in details.value as? String == limited }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [acceptedLimit], timeout: 15), .completed)
        let count = app.staticTexts["5,000 of 5,000 characters used"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "The accepted native draft must promptly publish its final counter.")
        scrollFullyIntoView(app, count, in: feedbackContent, presentedSheet: feedback)
        XCTAssertTrue(count.exists)
        capture(app, "Feedback visible input matches native grapheme limit")
        let review = app.buttons["Review"]
        scrollFullyIntoView(app, review, presentedSheet: feedback)
        XCTAssertTrue(review.wait(for: \.isEnabled, toEqual: true, timeout: 10)); review.tap()
        XCTAssertTrue(app.staticTexts["Review and submit"].waitForExistence(timeout: 10))
        let submit = app.buttons["Submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10)); XCTAssertTrue(submit.isEnabled)
        capture(app, "Feedback reviewed native context without submission")
        let feedbackBack = app.buttons["Back"]
        scrollFullyIntoView(app, feedbackBack, presentedSheet: feedback); feedbackBack.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 10)); XCTAssertEqual(details.value as? String, limited)
        close.tap()
        let discard = app.alerts["Discard feedback?"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10), "Sheet Close must respect the draft's own discard guard.")
        discard.buttons["Cancel"].tap()
        XCTAssertTrue(feedback.exists, "Cancelling discard must retain the sheet and draft.")
        close.tap()
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.buttons["Discard"].tap()
        XCTAssertTrue(feedbackRow.waitForExistence(timeout: 10))
        feedbackRow.tap()
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(feedbackRow.waitForExistence(timeout: 10), "A discarded draft must not return on reentry.")
        let qaRow = app.buttons["row.Device QA"]
        for _ in 0..<4 where !qaRow.isHittable { app.swipeUp() }
        XCTAssertTrue(qaRow.isHittable, app.debugDescription)
        qaRow.tap()
        let qa = app.otherElements["device-qa-page"]
        XCTAssertTrue(qa.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["Settings"].isHittable)
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        capture(app, "Device QA uses the same Settings page navigation")
        back.tap()
        XCTAssertTrue(qaRow.waitForExistence(timeout: 10))
        qaRow.tap()
        XCTAssertTrue(qa.waitForExistence(timeout: 10))
        nativeTab(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(qa.exists, "Settings reselection must pop the native Device QA route.")
    }

    func testRageShakeFeedbackDestinationRemainsAModalSheet() throws {
        // The existing DEBUG hook bypasses physical motion/preliminary consent.
        // Internal developer accounts first reach Device QA; its normal-user
        // action then exercises the real handoff into the Feedback sheet.
        let app = launch(rageShake: true)
        XCTAssertTrue(app.navigationBars["Device QA"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["Close"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
        capture(app, "Rage-shake Device QA retains bottom sheet Close chrome")
        let search = app.textFields["Search Device QA"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Normal User Feedback")
        let normalFeedback = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Normal User Feedback")).firstMatch
        XCTAssertTrue(normalFeedback.waitForExistence(timeout: 10), app.debugDescription)
        normalFeedback.tap()
        let feedback = app.navigationBars["Feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.otherElements["feedback-settings-page"].exists)
        XCTAssertTrue(app.navigationBars.buttons["Cancel"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
        capture(app, "Rage-shake destination retains bottom sheet Cancel chrome")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(feedback.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Guard"].isHittable)
    }

    func testUnusedFilterSharesDirectlyWithoutSwitching() throws {
        let app = launch()
        let filterEntry = app.buttons["guard.filter"]
        waitForSettledFrame(filterEntry)
        filterEntry.tap()
        let current = app.buttons["row.Now filtering"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        let activeBefore = current.label + String(describing: current.value)
        let chosen = current.label.contains("Core") ? "Balanced" : "Core"
        let library = app.buttons["row.Switch or manage filters"]
        waitForSettledFrame(library)
        library.tap()
        let inactive = app.buttons[chosen]
        XCTAssertTrue(inactive.waitForExistence(timeout: 10))
        waitForSettledFrame(inactive)
        inactive.tap()
        let choices = app.sheets[chosen]
        XCTAssertTrue(choices.waitForExistence(timeout: 10), app.debugDescription)
        for label in ["Switch to this filter", "View or edit only", "Share", "Cancel"] {
            XCTAssertTrue(choices.buttons[label].exists, label)
        }
        capture(app, "Unused filter offers switch view share and cancel")
        let share = choices.buttons["Share"]
        waitForSettledFrame(share)
        share.tap()
        let header = fullSheetHeader(app, title: "Share your filter")
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Show the QR code"].waitForExistence(timeout: 10))
        capture(app, "Unused saved filter opens contextual sharing directly")
        header.buttons["Close"].tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 10))
        XCTAssertTrue(inactive.waitForExistence(timeout: 10))
        let back = app.navigationBars["Your filters"].buttons["BackButton"]
        waitForSettledFrame(back)
        back.tap()
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.label + String(describing: current.value), activeBefore,
                       "Sharing must not switch the active filter.")
    }

    func testSharedPanelAndFooterLinksKeepExpandedTouchTargets() throws {
        let app = launch(paidPlan: true)
        func tapNearLabel(_ link: XCUIElement, verticalOffset: CGFloat) {
            scrollFullyIntoView(app, link, throughGutter: true)
            waitForSettledFrame(link)
            XCTAssertGreaterThanOrEqual(link.frame.height, 44)
            let frame = link.frame
            retainFrames(["accessible shared link": frame], name: "Shared footer target offset \(verticalOffset)")
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY + verticalOffset)
            ).tap()
        }
        XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings")!)
        let network = app.buttons["row.Network activity"]
        XCTAssertTrue(network.waitForExistence(timeout: 10))
        scrollFullyIntoView(app, network)
        network.tap()
        let networkIntro = "Connection and protection events stay on this device for 7 days. They leave it only if you include diagnostics when you send feedback."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", networkIntro)).firstMatch.waitForExistence(timeout: 10))
        capture(app, "Network activity retains its current shared information panel")
        for offset: CGFloat in [-20, 20] {
            XCUIDevice.shared.system.open(URL(string: "lavasecurity://guard")!)
            let activity = app.buttons["guard.today"]
            XCTAssertTrue(activity.waitForExistence(timeout: 10))
            waitForSettledFrame(activity)
            activity.tap()
            let privacy = app.links["Review Privacy & data"].firstMatch
            XCTAssertTrue(privacy.waitForExistence(timeout: 10), app.debugDescription)
            tapNearLabel(privacy, verticalOffset: offset)
            XCTAssertTrue(app.navigationBars["Privacy & data"].waitForExistence(timeout: 10),
                          "The shared Activity footer must remain tappable at \(offset)pt.")
            capture(app, "Shared Activity privacy footer edge opens its destination")
        }
        for offset: CGFloat in [-20, 20] {
            XCUIDevice.shared.system.open(URL(string: "lavasecurity://settings")!)
            let vpn = app.buttons["connection.vpn"]
            XCTAssertTrue(vpn.waitForExistence(timeout: 10))
            scrollFullyIntoView(app, vpn)
            waitForSettledFrame(vpn)
            vpn.tap()
            let setup = app.descendants(matching: .any).matching(identifier: "vpn.setup-toggle").firstMatch.switches.firstMatch
            XCTAssertTrue(setup.waitForExistence(timeout: 10))
            let originalSetup = setup.value as? String
            openVPNSetup(app)
            let link = app.links["Review DNS settings"].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
            tapNearLabel(link, verticalOffset: offset)
            XCTAssertTrue(app.navigationBars["DNS settings"].waitForExistence(timeout: 10),
                          "The shared VPN footer must remain tappable at \(offset)pt.")
            capture(app, "Shared VPN DNS footer edge opens its destination")
            nativeBack(app).tap()
            XCTAssertTrue(app.navigationBars["VPN chaining"].waitForExistence(timeout: 10))
            if originalSetup == "0" {
                scrollFullyIntoView(app, setup)
                waitForSettledFrame(setup)
                tapNativeSwitch(setup)
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    setup.value as? String == originalSetup
                }, object: nil)], timeout: 10), .completed)
            }
        }
    }


    func testImportAddsThenReplacesWithOneConfirmationAndPreservesSavedName() throws {
        let app = launch(paidPlan: true)
        // Production encoder payload with oisd-small and no allowed exceptions.
        let code = "LF1-MNi38X0Rq1ZKzMnJL09NUbKKjtVRSsrJT86GcZJLi0vycyHsnMzikmIgUyk_szhFtzgXqEsJKFymZGVUCwA"
        let filters = app.buttons["guard.filter"]
        waitForSettledFrame(filters)
        filters.tap()
        let current = app.buttons["row.Now filtering"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        let activeBefore = current.label + String(describing: current.value)
        func preview() {
            let importAction = app.navigationBars["Filters"].buttons["Import"]
            waitForSettledFrame(importAction)
            importAction.tap()
            let entry = app.buttons["Enter a code"]
            XCTAssertTrue(entry.waitForExistence(timeout: 10))
            waitForSettledFrame(entry)
            entry.tap()
            let editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            waitForSettledFrame(editor)
            editor.tap()
            editor.typeText(code)
            app.buttons["Continue"].tap()
            XCTAssertTrue(fullSheetHeader(app, title: "Review import").waitForExistence(timeout: 15), app.debugDescription)
        }
        preview()
        app.buttons["Add as a new filter"].tap()
        let completed = app.staticTexts["Filter imported"].firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 20), app.debugDescription)
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The shared filter was added to Your filters as “")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), app.debugDescription)
        let parts = saved.label.components(separatedBy: CharacterSet(charactersIn: "“”"))
        XCTAssertGreaterThan(parts.count, 2)
        let name = parts[1]
        XCTAssertFalse(name.isEmpty)
        let exactMessage = "The shared filter was added to Your filters as “\(name)”."
        XCTAssertEqual(saved.label, exactMessage)
        XCTAssertFalse(app.navigationBars.buttons["Back"].exists,
                       "Committed imports cannot navigate back and replay.")
        capture(app, "Add import confirms the exact saved generated name")
        app.buttons["Done"].tap()
        XCTAssertTrue(completed.waitForNonExistence(timeout: 10))
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.label + String(describing: current.value), activeBefore)
        preview()
        app.buttons["Replace a filter instead"].tap()
        let selection = fullSheetHeader(app, title: "Replace a filter")
        XCTAssertTrue(selection.waitForExistence(timeout: 10))
        let target = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        scrollFullyIntoView(app, target)
        XCTAssertTrue(target.isHittable, app.debugDescription)
        XCTAssertFalse(target.label.contains("In effect"), "Replace only this journey's new inactive filter.")
        waitForSettledFrame(target)
        target.tap()
        let review = fullSheetHeader(app, title: "Review import")
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        let replace = app.buttons["Replace a filter"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10))
        capture(app, "Replacement reviews the selected name and content diff before mutation")
        review.buttons["Back"].tap()
        XCTAssertTrue(selection.waitForExistence(timeout: 10))
        XCTAssertFalse(completed.exists, "Cancelling review must leave the target untouched and return to selection.")
        waitForSettledFrame(target)
        target.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        waitForSettledFrame(replace)
        replace.tap()
        XCTAssertTrue(completed.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts[exactMessage].firstMatch.exists)
        capture(app, "Reviewed replacement preserves the selected filter name")
        app.buttons["Done"].tap()
        XCTAssertTrue(completed.waitForNonExistence(timeout: 10))
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.label + String(describing: current.value), activeBefore)
        let library = app.buttons["row.Switch or manage filters"]
        waitForSettledFrame(library)
        library.tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 10))
        app.navigationBars["Your filters"].buttons["Edit"].tap()
        let deletion = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND value == %@", name)).firstMatch
        XCTAssertTrue(deletion.waitForExistence(timeout: 10))
        deletion.tap()
        app.navigationBars["Your filters"].buttons["Review changes"].tap()
        let commit = app.buttons["Confirm changes"]
        XCTAssertTrue(commit.waitForExistence(timeout: 10))
        waitForSettledFrame(commit)
        commit.tap()
        XCTAssertTrue(app.navigationBars["Your filters"].buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[name].exists)
    }

}
