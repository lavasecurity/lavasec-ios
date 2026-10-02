import XCTest

@MainActor
final class ReviewLifecycleTests: XCTestCase {
    func testNativeRoundTripRecreationForegroundAndPersistentRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-review-appearance", "--seed-native-qa-appearance", "--inspect-native-qa-appearance"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Confirmed: system"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Native QA reference: light"].exists)
        app.buttons["Open React Native"].tap()
        openAppearance(app)
        assertReactAppearance(app, value: "system")
        app.segmentedControls["Appearance"].buttons["Dark"].tap()
        assertReactAppearance(app, value: "dark")
        XCTAssertTrue(app.segmentedControls["Appearance"].buttons["Dark"].isSelected)
        attach(app, name: "Customization dark")
        closeFromAppearance(app)
        XCTAssertTrue(app.staticTexts["Confirmed: dark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Native QA reference: light"].exists)

        app.segmentedControls.buttons["light"].tap()
        app.buttons["Open React Native"].tap()
        openAppearance(app)
        assertReactAppearance(app, value: "light")
        XCUIDevice.shared.press(.home)
        app.activate()
        assertReactAppearance(app, value: "light")
        app.segmentedControls["Appearance"].buttons["Dark"].tap()
        assertReactAppearance(app, value: "dark")
        closeFromAppearance(app)
        attach(app, name: "Native fallback confirmed dark")
        app.terminate()
        app.launchArguments = ["--inspect-native-qa-appearance"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Confirmed: dark"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Native QA reference: light"].exists)
    }

    func testNativeFilterViewEditDomainSheetAndReview() {
        let app = launchReview()
        attach(app, name: "Guard light")
        app.buttons["Turn on"].tap()
        XCTAssertTrue(app.alerts["UI review build"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.buttons["row.How Lava filters"].tap()
        attach(app, name: "Filters light")
        XCTAssertTrue(app.buttons["row.Now filtering"].waitForExistence(timeout: 5))
        app.buttons["row.Now filtering"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Domain to block"].exists)
        attach(app, name: "Filter view light")
        app.buttons["Edit"].tap()
        let add = app.buttons["Block a domain"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let field = app.textFields["Domain to block"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add domain"].isEnabled)
        field.tap()
        field.typeText("Tracker.Example.NET.")
        field.typeText("\n")
        XCTAssertTrue(app.staticTexts["tracker.example.net"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["tracker.example.net"].exists)
        XCTAssertFalse(app.buttons["Confirm changes"].isEnabled)
        attach(app, name: "Filter review light")
        app.buttons["Close"].tap()
        app.buttons["Cancel editing"].tap()
        XCTAssertTrue(app.alerts["Discard changes?"].waitForExistence(timeout: 5))
        let discard = app.alerts["Discard changes?"].buttons["Discard"]
        let hittable = NSPredicate(format: "isHittable == true")
        expectation(for: hittable, evaluatedWith: discard)
        waitForExpectations(timeout: 5)
        discard.tap()
        XCTAssertTrue(app.alerts["Discard changes?"].waitForNonExistence(timeout: 5))
        attach(app, name: "Filter after discarding draft")
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["tracker.example.net"].exists)
        app.tabBars.buttons["Settings"].tap()
        app.buttons["row.Customization"].tap()
        app.buttons["Choose Lava Guard"].tap()
        XCTAssertTrue(app.navigationBars["Lava Guard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use Lava 3 days, Currently at: 0 days"].exists)
        attach(app, name: "Native guardian picker light")
    }

    func testCancelledDomainSheetDropsInputAndValidationError() {
        let app = launchReview()
        app.buttons["row.How Lava filters"].tap()
        XCTAssertTrue(app.buttons["row.Now filtering"].waitForExistence(timeout: 5))
        app.buttons["row.Now filtering"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        app.buttons["Block a domain"].tap()
        let field = app.textFields["Domain to block"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("invalid domain\n")
        let error = app.staticTexts["Enter a valid domain, such as ads.example.com."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        // UIKit exposes the underlying button to AX during dismissal, before it
        // can receive touches. Wait for this sheet's native teardown, not a delay.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        app.buttons["Block a domain"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "example.com")
        XCTAssertFalse(error.exists)
        XCTAssertFalse(app.buttons["Add domain"].isEnabled)
        attach(app, name: "Fresh native domain editor")
    }

    func testSettingsScaffoldRoutesAndSignedOutGates() {
        let app = launchReview()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["row.Account & Backup"].tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sign in with Google"].exists)
        XCTAssertFalse(app.buttons["Set up encrypted backup"].isEnabled)
        let automaticBackup = app.switches["Automatic backup"]
        let backupValue = automaticBackup.value as? String
        automaticBackup.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(automaticBackup.value as? String, backupValue)
        attach(app, name: "Account signed out light")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["row.Security"].tap()
        XCTAssertTrue(app.switches["Passcode"].waitForExistence(timeout: 5))
        let faceID = app.switches["Face ID"]
        let faceValue = faceID.value as? String
        faceID.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(faceID.value as? String, faceValue)
        attach(app, name: "Security gated light")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["row.DNS provider"].tap()
        XCTAssertTrue(app.switches["Use Device DNS setting"].waitForExistence(timeout: 5))
        attach(app, name: "DNS provider light")
        app.swipeUp()
        attach(app, name: "DNS provider lower light")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let stats = app.buttons["row.Nerd stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        for _ in 0..<3 where !stats.isHittable { app.swipeUp() }
        XCTAssertTrue(stats.isHittable)
        stats.tap()
        XCTAssertTrue(app.staticTexts["DNS tiers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["T1 · Primary DNS, Mullvad (DoH)\nDNS over HTTPS\ndns.mullvad.net"].exists)
        attach(app, name: "Nerd stats DNS tiers light")
    }

    func testSudokuEntryNotesAssistanceTrackingAndReset() {
        let app = launchReview()
        let mascot = app.descendants(matching: .any).matching(identifier: "guard.mascot").firstMatch
        XCTAssertTrue(mascot.waitForExistence(timeout: 5))
        openSudoku(mascot, in: app)
        let cell = app.buttons["sudoku-cell-0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Guard"].isHittable)
        attach(app, name: "Sudoku board light")

        let notes = app.buttons["sudoku-notes-toggle"]
        let assistance = app.buttons["sudoku-correctness-toggle"]
        let originalFrames = [notes.frame, assistance.frame]
        // Exercise all four combinations; a prominent button must not acquire
        // different bounds or shift the adjacent group while its mode changes.
        for (index, control) in [notes, assistance, notes, assistance].enumerated() {
            control.tap()
            for (button, original) in zip([notes, assistance], originalFrames) {
                XCTAssertEqual(button.frame.width, original.width, accuracy: 0.5)
                XCTAssertEqual(button.frame.height, original.height, accuracy: 0.5)
                XCTAssertEqual(button.frame.midX, original.midX, accuracy: 0.5)
                XCTAssertEqual(button.frame.midY, original.midY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            }
            attach(app, name: "Sudoku mode geometry combination \(index)")
        }

        cell.tap()
        app.buttons["sudoku-notes-toggle"].tap()
        app.buttons["sudoku-digit-1"].tap()
        app.buttons["sudoku-digit-3"].tap()
        XCTAssertEqual(cell.label, "Row 1, column 1: notes 1 3")
        attach(app, name: "Sudoku notes light")
        app.buttons["sudoku-notes-toggle"].tap()
        app.buttons["sudoku-digit-5"].tap()
        app.buttons["sudoku-correctness-toggle"].tap()
        XCTAssertEqual(cell.label, "Row 1, column 1: 5, Correctly placed")
        XCTAssertTrue(app.images["sudoku-correctness-outcome"].exists)
        let outcome = app.images["sudoku-correctness-outcome"]
        XCTAssertEqual(outcome.label, "Correctly placed")
        XCTAssertGreaterThanOrEqual(outcome.frame.width, 44)
        XCTAssertGreaterThanOrEqual(outcome.frame.height, 44)
        XCTAssertTrue(app.frame.contains(outcome.frame))
        attach(app, name: "Sudoku Eye correct-cell green checkmark")
        app.buttons["sudoku-eraser"].tap()
        XCTAssertEqual(cell.label, "Row 1, column 1: empty")

        let nextCell = app.buttons["sudoku-cell-2"]
        cell.press(forDuration: 0.1, thenDragTo: nextCell)
        app.buttons["sudoku-digit-1"].press(forDuration: 0.1, thenDragTo: app.buttons["sudoku-digit-9"])
        XCTAssertEqual(nextCell.label, "Row 1, column 3: 9, Misplaced")
        let firstKey = app.buttons["sudoku-digit-1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for offset: CGFloat in [-40, 40] {
            firstKey.press(forDuration: 0.1, thenDragTo: firstKey.withOffset(CGVector(dx: 0, dy: offset)))
            XCTAssertEqual(nextCell.label, "Row 1, column 3: 9, Misplaced")
        }
        attach(app, name: "Sudoku assistance and keypad tracking")
        app.buttons["sudoku-reset"].tap()
        XCTAssertTrue(app.alerts["Reset puzzle?"].waitForExistence(timeout: 5))
        attach(app, name: "Sudoku reset confirmation")
        app.alerts["Reset puzzle?"].buttons["Cancel"].tap()
        XCTAssertTrue(app.alerts["Reset puzzle?"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(nextCell.label, "Row 1, column 3: 9, Misplaced")
        app.buttons["sudoku-reset"].tap()
        app.alerts["Reset puzzle?"].buttons["Reset"].tap()
        XCTAssertTrue(app.alerts["Reset puzzle?"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(nextCell.label, "Row 1, column 3: empty")

        app.buttons["sudoku-refresh"].tap()
        XCTAssertTrue(app.alerts["New puzzle"].waitForExistence(timeout: 5))
        attach(app, name: "Sudoku new puzzle confirmation")
        app.alerts["New puzzle"].buttons["Cancel"].tap()
        XCTAssertTrue(app.alerts["New puzzle"].waitForNonExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(mascot.waitForExistence(timeout: 5))
        mascot.press(forDuration: 1.3)
        XCTAssertTrue(app.navigationBars["Lava Guard"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        app.segmentedControls.buttons["dark"].tap()
        app.buttons["Open React Native"].tap()
        XCTAssertTrue(mascot.waitForExistence(timeout: 5))
        openSudoku(mascot, in: app)
        XCTAssertTrue(app.buttons["sudoku-cell-0"].waitForExistence(timeout: 5))
        attach(app, name: "Sudoku board dark and status bar")
    }

    private func openSudoku(_ mascot: XCUIElement, in app: XCUIApplication) {
        // Resolve coordinates before the timed sequence. XCTest may still insert
        // an idle wait longer than the app's 0.5s inter-tap window on a busy VM
        // (the window is deliberately tight so the five taps must be consecutive),
        // so a single cadence can miss; retry the whole burst. Retry only this
        // entry gesture; all board assertions run once afterward.
        let frame = mascot.frame
        let appFrame = app.frame
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.midX - appFrame.minX, dy: frame.midY - appFrame.minY)
        )
        for _ in 0..<5 {
            for _ in 0..<5 { center.tap() }
            if app.buttons["sudoku-cell-0"].waitForExistence(timeout: 5) { return }
        }
        XCTFail("Five separate mascot taps did not open Sudoku.")
    }

    private func launchReview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-review-appearance"]
        app.launch()
        app.buttons["Open React Native"].tap()
        XCTAssertTrue(app.buttons["row.How Lava filters"].waitForExistence(timeout: 20))
        return app
    }

    func testAsyncNativeChoiceKeepsIntentUntilOwnerSettlement() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-review-appearance"]
        app.launch()
        app.buttons["Open component gallery"].tap()
        let control = app.segmentedControls["Async confirmation"]
        XCTAssertTrue(control.waitForExistence(timeout: 20))
        for _ in 0..<4 where !control.isHittable { app.swipeUp() }
        control.buttons["Focused"].tap()
        XCTAssertTrue(control.buttons["Focused"].isSelected)
        XCTAssertTrue(app.staticTexts["Saved async choice: normal"].exists)
        attach(app, name: "Native async selector pending without snapback")
        app.buttons["Cancel choice"].tap()
        XCTAssertTrue(control.buttons["Normal"].isSelected)
        control.buttons["Focused"].tap()
        XCTAssertTrue(control.buttons["Focused"].isSelected)
        app.buttons["Accept choice"].tap()
        XCTAssertTrue(app.staticTexts["Saved async choice: focused"].waitForExistence(timeout: 5))
        XCTAssertTrue(control.buttons["Focused"].isSelected)
        attach(app, name: "Native async selector accepted")
    }

    func testNativeChoiceWaitsForOwnerConfirmationAndHonorsDisabledState() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-review-appearance"]
        app.launch()
        app.buttons["Open component gallery"].tap()
        let pending = app.segmentedControls["Pending confirmation"]
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        for _ in 0..<3 where !pending.isHittable { app.swipeUp() }
        XCTAssertTrue(pending.buttons["Normal"].isSelected)
        pending.buttons["Focused"].tap()
        XCTAssertTrue(app.staticTexts["Requested: focused · Confirmed: normal"].waitForExistence(timeout: 5))
        XCTAssertTrue(pending.buttons["Normal"].isSelected)
        XCTAssertFalse(pending.buttons["Focused"].isSelected)
        let disabled = app.segmentedControls["Disabled choice"]
        for _ in 0..<3 where !disabled.isHittable { app.swipeUp() }
        // UIKit reports the current segment as Selected, even in a disabled group.
        // Verify the alternative's disabled trait and actual taps on both segments.
        XCTAssertFalse(disabled.buttons["Focused"].isEnabled, disabled.debugDescription)
        disabled.buttons["Normal"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        disabled.buttons["Focused"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(disabled.buttons["Normal"].isSelected)
        XCTAssertFalse(disabled.buttons["Focused"].isSelected)
        XCTAssertTrue(app.staticTexts["Disabled choice requests: 0"].exists)
        attach(app, name: "Native choices confirmed and disabled")
    }

    func testPopulatedActivityChartsUseTheIsolatedWelcomeFixture() throws {
        // This app has a separate bundle/preferences domain and no tunnel. The
        // sample is selected at its existing native welcome, never injected into
        // the full app's diagnostics store or a production command.
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-review-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.buttons["Open React Native"].waitForExistence(timeout: 10))
            app.segmentedControls.buttons[appearance].tap()
            app.segmentedControls.buttons["Example"].tap()
            app.buttons["Open React Native"].tap()
            XCTAssertTrue(app.buttons["guard.today"].waitForExistence(timeout: 20))
            attach(app, name: "Guard Today blocked-left summary \(appearance)")
            app.buttons["guard.today"].tap()
            XCTAssertTrue(app.staticTexts["3,246"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.segmentedControls["Activity sample"].exists)

            let cycle = app.buttons["activity.chart.next"]
            let total = app.descendants(matching: .any).matching(identifier: "activity.plot.total").firstMatch
            let inspect = app.descendants(matching: .any).matching(identifier: "activity.total.inspect").firstMatch
            XCTAssertTrue(inspect.waitForExistence(timeout: 10))
            let chartHeight = total.frame.height
            let baselineY = inspect.frame.maxY
            XCTAssertGreaterThan(chartHeight, 0)
            func expectValue(_ element: XCUIElement, _ value: String) {
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, element.debugDescription)
            }
            func expectLegends(_ allowed: String, _ blocked: String) {
                for (outcome, label, value) in [("allowed", "Allowed", allowed), ("blocked", "Blocked", blocked)] {
                    let legend = app.descendants(matching: .any).matching(identifier: "legend.\(outcome)").firstMatch
                    let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "\(label), \(value)"), object: legend)
                    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, legend.debugDescription)
                }
            }
            func inspectBucket(_ element: XCUIElement, _ index: Int) {
                element.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(index) + 0.5) / 6, dy: 0.5)).tap()
            }
            inspect.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            expectValue(inspect, "Blocked, 598")
            expectLegends("2,648 (82%)", "598 (18%)")
            attach(app, name: "Activity Total blocked-left inspection \(appearance)")
            inspect.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            expectValue(inspect, "Allowed, 2,648")
            expectLegends("2,648 (82%)", "598 (18%)")
            XCTAssertTrue(app.staticTexts["3,246"].exists, "Inspecting an outcome retains the aggregate total.")
            attach(app, name: "Activity Total allowed-right inspection \(appearance)")
            app.descendants(matching: .any).matching(identifier: "legend.allowed").firstMatch.tap()
            expectValue(inspect, "3,246")

            cycle.tap()
            let counts = app.descendants(matching: .any).matching(identifier: "activity.plot.counts").firstMatch
            XCTAssertTrue(counts.waitForExistence(timeout: 10))
            XCTAssertEqual(counts.frame.height, chartHeight, accuracy: 1)
            let baseline = app.descendants(matching: .any).matching(identifier: "activity.baseline").firstMatch
            XCTAssertEqual(baseline.frame.maxY, baselineY, accuracy: 1.5)
            inspectBucket(counts, 0)
            expectValue(counts, "09:00, 800 Allowed, 200 Blocked")
            expectLegends("800 (80%)", "200 (20%)")
            attach(app, name: "Activity populated counts mixed inspection \(appearance)")
            // A short positive stack exposes a full-height selection outline;
            // the existing mixed bucket is nearly the tallest in this fixture.
            inspectBucket(counts, 5)
            expectValue(counts, "14:00, 0 Allowed, 200 Blocked")
            expectLegends("0 (0%)", "200 (100%)")
            attach(app, name: "Activity populated short bar fitted selection \(appearance)")
            inspectBucket(counts, 1)
            expectValue(counts, "10:00, 0 Allowed, 0 Blocked")
            expectLegends("0 (0%)", "0 (0%)")
            inspectBucket(counts, 2)
            expectValue(counts, "No data")
            expectLegends("—", "—")
            attach(app, name: "Activity populated counts unavailable interval \(appearance)")
            app.descendants(matching: .any).matching(identifier: "legend.allowed").firstMatch.tap()
            expectValue(counts, "Drag to inspect")

            cycle.tap()
            let rate = app.descendants(matching: .any).matching(identifier: "activity.plot.rate").firstMatch
            XCTAssertTrue(rate.waitForExistence(timeout: 10))
            XCTAssertEqual(rate.frame.height, chartHeight, accuracy: 1)
            XCTAssertEqual(baseline.frame.maxY, baselineY, accuracy: 1.5)
            inspectBucket(rate, 0)
            expectValue(rate, "09:00, 20% Blocked")
            expectLegends("800 (80%)", "200 (20%)")
            // Actual captures qualify the complete circular border; accessibility
            // values alone cannot establish that a connecting line stays behind it.
            attach(app, name: "Activity rate first selected 5pt marker \(appearance)")
            inspectBucket(rate, 1)
            expectValue(rate, "10:00, No requests")
            expectLegends("0 (0%)", "0 (0%)")
            inspectBucket(rate, 2)
            expectValue(rate, "No data")
            expectLegends("—", "—")
            inspectBucket(rate, 3)
            expectValue(rate, "12:00, 19% Blocked")
            expectLegends("848 (81%)", "198 (19%)")
            attach(app, name: "Activity rate middle selected 5pt marker \(appearance)")
            inspectBucket(rate, 4)
            expectValue(rate, "13:00, 0% Blocked")
            expectLegends("1,000 (100%)", "0 (0%)")
            attach(app, name: "Activity populated rate genuine zero percent \(appearance)")
            inspectBucket(rate, 5)
            expectValue(rate, "14:00, 100% Blocked")
            expectLegends("0 (0%)", "200 (100%)")
            attach(app, name: "Activity rate last selected marker without Partial caption \(appearance)")
            app.segmentedControls["activity.period"].buttons["7 days"].tap()
            expectValue(rate, "Drag to inspect")
            cycle.tap()
            expectValue(inspect, "0")
            expectLegends("0 (0%)", "0 (0%)")
            app.terminate()
        }
    }

    func testActivityMatchesNativeDateSheetAndKeepsFixturesOutsideTheScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-review-appearance"]
        app.launch()
        app.segmentedControls.buttons["dark"].tap()
        app.segmentedControls.buttons["Example"].tap()
        app.buttons["Open React Native"].tap()
        XCTAssertTrue(app.buttons["row.What Lava has caught"].waitForExistence(timeout: 20))
        app.buttons["row.What Lava has caught"].tap()
        XCTAssertTrue(app.staticTexts["3,246"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Today"].exists)
        XCTAssertFalse(app.segmentedControls["Activity range"].exists)
        XCTAssertFalse(app.segmentedControls["Preview data"].exists)
        XCTAssertFalse(app.staticTexts["UI preview · sample data · no VPN"].exists)
        attach(app, name: "Activity native reference example dark")
        app.buttons["Today"].tap()
        XCTAssertTrue(app.navigationBars["Change Dates"].waitForExistence(timeout: 5))
        attach(app, name: "Activity original native calendar dark")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Change Dates"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3,246"].exists)
        app.buttons["Today"].tap()
        XCTAssertTrue(app.navigationBars["Change Dates"].waitForExistence(timeout: 5))
        // The calendar opens at the latest month. Choose an earlier day in this
        // month when available; day one still exercises confirmed Today/reset.
        let today = Calendar.current.component(.day, from: Date())
        if today > 1 {
            let day = try XCTUnwrap(app.buttons.matching(identifier: String(today - 1)).allElementsBoundByIndex.last)
            if !day.isHittable { app.navigationBars["Change Dates"].swipeUp() }
            day.tap()
            day.tap()
        }
        app.buttons["Show Activity"].tap()
        XCTAssertTrue(app.navigationBars["Change Dates"].waitForNonExistence(timeout: 5))
        if today > 1 { XCTAssertTrue(app.staticTexts["0"].waitForExistence(timeout: 5)) }
        app.navigationBars["Activity"].buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["Reset Activity dates to today"].waitForExistence(timeout: 5))
        app.buttons["Reset Activity dates to today"].tap()
        app.buttons["Show Activity"].tap()
        XCTAssertTrue(app.staticTexts["3,246"].waitForExistence(timeout: 5))
        let privacy = app.links["Review Privacy & data"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy & data"].waitForExistence(timeout: 5))
        for _ in 0..<2 { app.navigationBars.buttons.element(boundBy: 0).tap() }
        app.navigationBars.firstMatch.tap(withNumberOfTaps: 2, numberOfTouches: 3)
        XCTAssertTrue(app.buttons["Open React Native"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["light"].tap()
        app.buttons["Open React Native"].tap()
        XCTAssertTrue(app.buttons["row.What Lava has caught"].waitForExistence(timeout: 20))
        app.buttons["row.What Lava has caught"].tap()
        XCTAssertTrue(app.staticTexts["3,246"].waitForExistence(timeout: 5))
        attach(app, name: "Activity native reference example light")
    }

    func testExploreMeasuredStepDragKeepsPageStillAndReleasesScrollingInBothThemes() throws {
        XCUIDevice.shared.orientation = .portrait
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            // Large text makes this real page scrollable, so release is checked
            // through actual movement rather than a no-op on a short page.
            app.launchArguments = ["--reset-review-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            XCTAssertTrue(app.buttons["Open React Native"].waitForExistence(timeout: 10))
            app.segmentedControls.buttons[appearance].tap()
            app.buttons["Open React Native"].tap()
            let explore = app.buttons["guard.explore"]
            XCTAssertTrue(explore.waitForExistence(timeout: 20))
            for _ in 0..<6 where !explore.isHittable { app.swipeUp() }
            XCTAssertTrue(explore.isHittable)
            explore.tap()
            let phone = app.buttons["connection.phone"]
            let filter = app.buttons["connection.filter"]
            XCTAssertTrue(phone.waitForExistence(timeout: 10))
            XCTAssertTrue(phone.isHittable)
            XCTAssertTrue(filter.isHittable)
            func expectSelected(_ element: XCUIElement) {
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, element.debugDescription)
            }
            phone.tap()
            expectSelected(phone)
            attach(app, name: "Explore selected white Device outline large text \(appearance)")
            let phoneBefore = phone.frame
            let filterBefore = filter.frame
            let start = phone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            // This crosses actual measured node frames; no synthetic selector
            // or direct callback bypasses the native responder/page coordinates.
            start.press(forDuration: 0.15, thenDragTo: end, withVelocity: 100, thenHoldForDuration: 0.3)
            expectSelected(filter)
            XCTAssertFalse(phone.isSelected)
            XCTAssertEqual(phone.frame.minY, phoneBefore.minY, accuracy: 2, "Tracking must not scroll the page.")
            XCTAssertEqual(filter.frame.minY, filterBefore.minY, accuracy: 2)
            attach(app, name: "Explore dragged white Filter outline stable page large text \(appearance)")

            // Fabric places testID on an Other wrapper; the actual ScrollView
            // is its unlabelled descendant (confirmed in the exported AX tree).
            let scrollSurface = app.descendants(matching: .any).matching(identifier: "screen.scroll").firstMatch
            XCTAssertTrue(scrollSurface.exists)
            XCTAssertEqual(scrollSurface.scrollViews.count, 1, scrollSurface.debugDescription)
            let viewport = scrollSurface.scrollViews.firstMatch
            XCTAssertTrue(viewport.exists)
            let bounds = viewport.frame.intersection(app.frame)
            XCTAssertGreaterThan(bounds.height, 200)
            let anchorY = filter.frame.minY
            // The outer scroll gutter avoids beginning another step inspection.
            let scrollStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.maxX - app.frame.minX - 3, dy: bounds.midY + 70 - app.frame.minY))
            let scrollEnd = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.maxX - app.frame.minX - 3, dy: bounds.midY - 70 - app.frame.minY))
            scrollStart.press(forDuration: 0.1, thenDragTo: scrollEnd, withVelocity: 100, thenHoldForDuration: 0.2)
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(filter.frame.minY - anchorY) > 8 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "The page must scroll after the step gesture releases its lock.")
            expectSelected(filter)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            attach(app, name: "Explore page scrolling restored after step drag large text \(appearance)")
            app.terminate()
        }
    }

    private func openAppearance(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["row.Customization"].tap()
        let appearance = app.segmentedControls["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        if !appearance.isHittable { app.swipeUp() }
        XCTAssertEqual(appearance.buttons.allElementsBoundByIndex.map(\.label), ["Light", "Dark", "System"])
    }

    private func closeFromAppearance(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.firstMatch.tap(withNumberOfTaps: 2, numberOfTouches: 3)
        XCTAssertTrue(app.buttons["Open React Native"].waitForExistence(timeout: 5))
    }

    private func assertReactAppearance(_ app: XCUIApplication, value: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = app.segmentedControls["Appearance"].buttons[value.capitalized]
        let confirmed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND selected == true"), object: segment)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 20), .completed, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
