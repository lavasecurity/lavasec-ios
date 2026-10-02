import XCTest

@MainActor
final class SecuritySettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSudokuCellSelectionAndDigitEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lava-sudoku-ui-test"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        let firstDigit = app.buttons["sudoku-digit-1"]
        XCTAssertTrue(firstDigit.waitForExistence(timeout: 10))
        XCTAssertFalse(firstDigit.isEnabled, "Digits stay disabled until an editable cell is selected")
        let givenCells = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sudoku-cell-")
        )
        let originalGivens = Dictionary(uniqueKeysWithValues: givenCells.allElementsBoundByIndex.map {
            ($0.identifier, $0.label)
        })
        XCTAssertFalse(originalGivens.isEmpty)

        let editableCells = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sudoku-cell-")
        )
        XCTAssertGreaterThan(editableCells.count, 0, "A generated puzzle must expose editable cells")

        let emptyCell = editableCells.allElementsBoundByIndex.first { $0.label.contains(": empty") }
        let cell = try XCTUnwrap(emptyCell, "A generated puzzle must contain an empty editable cell")
        cell.tap()

        XCTAssertTrue(firstDigit.isEnabled, "Selecting an editable cell must enable digit entry")
        firstDigit.tap()
        XCTAssertTrue(
            cell.label.hasSuffix(": 1"),
            "Tapping a digit must place it in the selected cell; got label: \(cell.label)"
        )

        let correctnessToggle = app.buttons["sudoku-correctness-toggle"]
        correctnessToggle.tap()
        let onesGiven = originalGivens.values.filter { $0.hasSuffix(": 1, given") }.count
        XCTAssertEqual(firstDigit.value as? String, "\(max(0, 8 - onesGiven)) remaining")
        XCTAssertTrue(
            cell.label.contains("Correctly placed") || cell.label.contains("Misplaced"),
            "Eye-open mode must announce the selected value's correctness; got label: \(cell.label)"
        )
        let expectedOutcome = cell.label.contains("Correctly placed") ? "Correctly placed" : "Misplaced"
        let correctnessOutcome = app.images["sudoku-correctness-outcome"]
        XCTAssertTrue(
            correctnessOutcome.waitForExistence(timeout: 2),
            "Eye-open mode must show a check or cross above the board"
        )
        XCTAssertEqual(correctnessOutcome.label, expectedOutcome)
        correctnessToggle.tap()
        XCTAssertEqual(firstDigit.value as? String ?? "", "", "Closing the eye hides remaining counts")
        XCTAssertTrue(cell.label.hasSuffix(": 1"), "Eye-closed mode must hide the correctness announcement")
        XCTAssertFalse(
            correctnessOutcome.waitForExistence(timeout: 0.5),
            "Eye-closed mode must hide the correctness outcome glyph"
        )

        let eraser = app.buttons["sudoku-eraser"]
        XCTAssertTrue(eraser.waitForExistence(timeout: 2), "The contextual eraser appears for a filled selected cell")
        XCTAssertGreaterThan(eraser.frame.width, firstDigit.frame.width * 2.5, "The eraser must span the 4-5-6 columns")
        XCTAssertLessThan(eraser.frame.height, firstDigit.frame.height, "The wide eraser must stay shorter than digit keys")
        XCTAssertEqual(eraser.frame.minX, app.buttons["sudoku-digit-4"].frame.minX, accuracy: 1)
        XCTAssertEqual(eraser.frame.maxX, app.buttons["sudoku-digit-6"].frame.maxX, accuracy: 1)
        XCTAssertEqual(firstDigit.frame.minY - eraser.frame.maxY, 18, accuracy: 1,
                       "The eraser must stay clearly separated from the number row")
        let keypadScreenshot = XCTAttachment(screenshot: app.screenshot())
        keypadScreenshot.name = "Nine digits and wide eraser"
        keypadScreenshot.lifetime = .keepAlways
        add(keypadScreenshot)
        eraser.tap()
        XCTAssertTrue(cell.label.hasSuffix(": empty"), "The keypad eraser must clear the selected value")

        let firstDigitCenter = firstDigit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let aboveKeypad = firstDigit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.75))
        firstDigitCenter.press(forDuration: 0.15, thenDragTo: aboveKeypad)
        XCTAssertTrue(
            cell.label.hasSuffix(": empty"),
            "Releasing a keypad scrub outside its bounds must cancel without placing a digit"
        )

        let ninthDigit = app.buttons["sudoku-digit-9"]
        firstDigit.press(forDuration: 0.15, thenDragTo: ninthDigit)
        XCTAssertTrue(
            cell.label.hasSuffix(": 9"),
            "Scrubbing the keypad must commit the key under the finger on release; got label: \(cell.label)"
        )

        let nextEmptyCell = try XCTUnwrap(
            editableCells.allElementsBoundByIndex.last { $0.label.contains(": empty") },
            "A generated puzzle must contain another empty editable cell"
        )
        cell.press(forDuration: 0.1, thenDragTo: nextEmptyCell)

        let secondDigit = app.buttons["sudoku-digit-2"]
        XCTAssertTrue(secondDigit.isEnabled, "Finger tracking must leave the last editable cell selected")
        secondDigit.tap()
        XCTAssertTrue(
            nextEmptyCell.label.hasSuffix(": 2"),
            "Dragging the selector must retarget digit entry; got label: \(nextEmptyCell.label)"
        )
        let notesToggle = app.buttons["sudoku-notes-toggle"]
        let noteCell = try XCTUnwrap(
            editableCells.allElementsBoundByIndex.first { $0.label.contains(": empty") },
            "A generated puzzle must retain another empty editable cell for notes"
        )
        noteCell.tap()
        notesToggle.tap()
        let thirdDigit = app.buttons["sudoku-digit-3"]
        thirdDigit.tap()
        XCTAssertTrue(noteCell.label.contains("notes 3"), "Pencil mode must reveal the saved candidate")
        XCTAssertTrue(thirdDigit.isSelected, "A noted candidate must highlight its matching digit key")
        thirdDigit.tap()
        XCTAssertFalse(thirdDigit.isSelected, "Removing a candidate must clear the digit-key selection")
        thirdDigit.tap()
        XCTAssertTrue(thirdDigit.isSelected)
        correctnessToggle.tap()
        let notesScreenshot = XCTAttachment(screenshot: app.screenshot())
        notesScreenshot.name = "Selected candidate and remaining counts"
        notesScreenshot.lifetime = .keepAlways
        add(notesScreenshot)
        correctnessToggle.tap()
        notesToggle.tap()
        XCTAssertTrue(noteCell.label.hasSuffix(": empty"), "Leaving pencil mode must hide candidate notes")
        notesToggle.tap()
        XCTAssertTrue(noteCell.label.contains("notes 3"), "Re-entering pencil mode must reveal retained notes")

        let reset = app.buttons["sudoku-reset"]
        reset.tap()
        let resetAlert = app.alerts["Reset puzzle?"]
        XCTAssertTrue(resetAlert.waitForExistence(timeout: 2), "Reset must use a confirmation alert")
        resetAlert.buttons["Cancel"].tap()
        XCTAssertTrue(noteCell.label.contains("notes 3"), "Cancelling reset must preserve the current game")
        reset.tap()
        XCTAssertTrue(resetAlert.waitForExistence(timeout: 2))
        resetAlert.buttons["Reset"].tap()
        XCTAssertTrue(noteCell.label.hasSuffix(": empty"), "Reset must clear progress while keeping the puzzle")
        XCTAssertTrue(cell.label.hasSuffix(": empty"), "Reset clears placed digits too")
        XCTAssertTrue(nextEmptyCell.label.hasSuffix(": empty"))
        notesToggle.tap()
        XCTAssertTrue(noteCell.label.hasSuffix(": empty"), "Reset clears notes, rather than merely hiding them")
        notesToggle.tap()
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: givenCells.allElementsBoundByIndex.map { ($0.identifier, $0.label) }),
            originalGivens,
            "Reset must preserve every original clue"
        )
        cell.tap()
        firstDigit.tap()

        // Assistance reports remaining counts without restricting placement. Cross zero while
        // entering values, then replace an entry to ensure the key never becomes a dead control.
        correctnessToggle.tap()
        for target in editableCells.allElementsBoundByIndex.filter({ $0.label.contains(": empty") }).prefix(9 - onesGiven) {
            target.tap()
            XCTAssertTrue(firstDigit.isEnabled, "Zero remaining is informational, not an input lock")
            firstDigit.tap()
            XCTAssertTrue(target.label.contains(": 1,"))
        }
        XCTAssertEqual(firstDigit.value as? String, "0 remaining")
        secondDigit.tap()
        XCTAssertTrue(firstDigit.isEnabled)
        firstDigit.tap()
        XCTAssertEqual(firstDigit.value as? String, "0 remaining")
        correctnessToggle.tap()

        let refresh = app.buttons["sudoku-refresh"]
        refresh.tap()
        let refreshAlert = app.alerts["New puzzle"]
        XCTAssertTrue(refreshAlert.waitForExistence(timeout: 2), "New puzzle must use a confirmation alert")
        refreshAlert.buttons["Cancel"].tap()
        XCTAssertTrue(cell.label.hasSuffix(": 1"), "Cancelling refresh preserves progress")
        refresh.tap()
        XCTAssertTrue(refreshAlert.waitForExistence(timeout: 2))
        refreshAlert.buttons["New puzzle"].tap()
        XCTAssertFalse(firstDigit.isEnabled, "Refreshing clears the input selection")
        XCTAssertNotEqual(
            Dictionary(uniqueKeysWithValues: givenCells.allElementsBoundByIndex.map { ($0.identifier, $0.label) }),
            originalGivens,
            "Confirmed refresh generates a new puzzle"
        )
    }

    func testSudokuEntryColorsWithAssistanceInLightAndDarkMode() throws {
        let app = XCUIApplication()
        for style in ["Light", "Dark"] {
            app.launchArguments = ["-lava-sudoku-ui-test"]
            if style == "Dark" { app.launchArguments.append("-lava-sudoku-dark-ui-test") }
            app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
            app.launch()
            XCTAssertTrue(app.buttons["sudoku-digit-1"].waitForExistence(timeout: 10))
            let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sudoku-cell-"))
            let emptyCells = cells.allElementsBoundByIndex.filter { $0.label.hasSuffix(": empty") }
            XCTAssertGreaterThanOrEqual(emptyCells.count, 2)
            let correctCell = emptyCells[0]
            let incorrectCell = emptyCells[1]
            let eye = app.buttons["sudoku-correctness-toggle"]
            eye.tap()
            correctCell.tap()
            // Learn a correct placement through the same assistance the player sees, without
            // coupling this screenshot test to a generator-specific solution or debug-only colors.
            for value in 1...9 {
                app.buttons["sudoku-digit-\(value)"].tap()
                if correctCell.label.contains("Correctly placed") { break }
            }
            XCTAssertTrue(correctCell.label.contains("Correctly placed"))
            incorrectCell.tap()
            app.buttons["sudoku-digit-1"].tap()
            if incorrectCell.label.contains("Correctly placed") {
                app.buttons["sudoku-digit-2"].tap()
            }
            XCTAssertTrue(incorrectCell.label.contains("Misplaced"))
            XCTAssertEqual(app.images["sudoku-correctness-outcome"].label, "Misplaced")
            let assisted = XCTAttachment(screenshot: app.screenshot())
            assisted.name = "\(style) - green correct and orange incorrect entries"
            assisted.lifetime = .keepAlways
            add(assisted)

            eye.tap()
            XCTAssertFalse(correctCell.label.contains("Correctly placed"))
            XCTAssertFalse(incorrectCell.label.contains("Misplaced"))
            XCTAssertFalse(app.images["sudoku-correctness-outcome"].exists)
            let unassisted = XCTAttachment(screenshot: app.screenshot())
            unassisted.name = "\(style) - both user entries green with eye closed"
            unassisted.lifetime = .keepAlways
            add(unassisted)
            eye.tap()
            XCTAssertTrue(correctCell.label.contains("Correctly placed"))
            XCTAssertTrue(incorrectCell.label.contains("Misplaced"))
            app.terminate()
        }
    }

    func testSudokuKeepsFullLayoutAcrossKeyboardAndForeground() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lava-sudoku-ui-test", "-lava-sudoku-keyboard-ui-test"]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let digit = app.buttons["sudoku-digit-1"]
        XCTAssertTrue(digit.waitForExistence(timeout: 10))
        let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sudoku-cell-"))
        let cell = try XCTUnwrap(cells.allElementsBoundByIndex.first { $0.label.hasSuffix(": empty") })
        cell.tap()
        digit.tap()
        let cellFrame = cell.frame
        let digitFrame = digit.frame

        app.buttons["sudoku-test-show-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let keyboardScreenshot = XCTAttachment(screenshot: app.screenshot())
        keyboardScreenshot.name = "Sudoku with real keyboard inset"
        keyboardScreenshot.lifetime = .keepAlways
        add(keyboardScreenshot)
        XCTAssertEqual(cell.frame.width, cellFrame.width, accuracy: 1,
                       "An unrelated keyboard must not shrink the board")
        XCTAssertEqual(digit.frame.minY, digitFrame.minY, accuracy: 1,
                       "An unrelated keyboard must not lift the keypad")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.buttons["sudoku-test-hide-keyboard"].waitForExistence(timeout: 5))
        app.buttons["sudoku-test-hide-keyboard"].tap()
        let keyboardGone = NSPredicate(format: "exists == false")
        expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(cell.frame.width, cellFrame.width, accuracy: 1)
        XCTAssertEqual(cell.frame.minY, cellFrame.minY, accuracy: 1)
        XCTAssertEqual(digit.frame.minY, digitFrame.minY, accuracy: 1)
        XCTAssertTrue(cell.label.hasSuffix(": 1"), "Foregrounding must retain the current puzzle entry")
        app.buttons["sudoku-digit-2"].tap()
        XCTAssertTrue(cell.label.hasSuffix(": 2"), "Selection and input must work without restarting")
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
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("Change settings", in: app)

        tapBack(in: app)

        tapButton("DNS Resolver", in: app)
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("Open Lava", in: app)

        app.terminate()
        app.launchEnvironment = [:]
        app.launch()

        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("Open Lava", in: app)
        tapBack(in: app)

        tapRootTab("Guard", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))

        openGuardSection("How Lava filters", in: app)
        XCTAssertTrue(app.staticTexts["Filters"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))
        tapBack(in: app)

        openGuardSection("What Lava has caught", in: app)
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))
        tapBack(in: app)

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))
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
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))

        tapBack(in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Open Security settings"].waitForExistence(timeout: 2))

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Authentication"].waitForExistence(timeout: 5))

        tapBack(in: app)
        tapRootTab("Guard", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))

        tapRootTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Your Lava"].waitForExistence(timeout: 5))

        tapButton("Security", in: app)
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("Turn protection on or off", in: app)

        tapBack(in: app)
        tapRootTab("Guard", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))

        tapProtectionPrimaryAction(in: app)
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Change Lava protection"].waitForExistence(timeout: 2))

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))

        tapProtectionPrimaryAction(in: app)
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Use authentication for"].waitForExistence(timeout: 5))
        tapSwitch("View Activity", in: app)

        tapBack(in: app)
        openGuardSection("What Lava has caught", in: app)
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unlock to view Activity"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Authentication Required"].exists)
        XCTAssertFalse(app.staticTexts["Unlock to view local activity"].exists)
        XCTAssertTrue(app.buttons["Authenticate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Enter passcode"].waitForExistence(timeout: 1))

        app.buttons["Authenticate"].tap()
        XCTAssertTrue(app.staticTexts["Enter passcode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["View Activity"].waitForExistence(timeout: 2))

        enterPasscode("1234", in: app)
        XCTAssertTrue(app.staticTexts["Domain Logs"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Set passcode"].waitForExistence(timeout: 5))
        enterPasscode("1234", in: app)

        XCTAssertTrue(app.staticTexts["Confirm passcode"].waitForExistence(timeout: 5))
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
