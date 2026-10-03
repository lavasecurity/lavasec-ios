import XCTest

/// Pins the Sudoku easter egg's tap-input contract AS TEXT (the app target sits outside the
/// SPM test target, per the SourceTests regime in SourceIntrospectionSupport.swift).
///
/// Why a pin exists at all: the game's input layer regressed three times (v2 drag rework,
/// eraser/notes no-ops, tap-flow rebuild), and two of the three merged without any test
/// noticing — the model suite (`SudokuGameStateTests`) exercises the pure engine, never the
/// view wiring that routes a cell tap to `selectedIndex` and a digit tap to `enterDigit`. A
/// merged regression of this class reads as "untestable UI"; these assertions make the
/// input-flow invariants visible and fail-able in CI instead.
///
/// Pin hygiene: function-scoped assertions are extracted with `sourceBlock` and evaluated in
/// ORDER inside their block, so a regression that deletes the call under test cannot stay green
/// merely because the same token exists in a sibling function. Bans over whole-line rationale
/// comments (the drag-machinery ban) run over `sourceExcludingComments(source)` so the pin
/// cannot trip on its own explanatory prose.
final class SudokuTapInputContractSourceTests: XCTestCase {
    private let source = try! readSource(.sudokuEasterEggView)

    private var handleCellTapBlock: String {
        try! sourceBlock(in: source, startingAt: "private func handleCellTap", endingBefore: "private func selectCell")
    }

    private var selectCellBlock: String {
        try! sourceBlock(in: source, startingAt: "private func selectCell", endingBefore: "private func enterDigit")
    }

    private var enterDigitBlock: String {
        try! sourceBlock(in: source, startingAt: "private func enterDigit", endingBefore: "private func eraseCell")
    }

    private var eraseCellBlock: String {
        try! sourceBlock(in: source, startingAt: "private func eraseCell", endingBefore: "private func startFreshPuzzle")
    }

    private var keypadTrackingBlock: String {
        try! sourceBlock(in: source, startingAt: "private func trackKeypadTouch", endingBefore: "private func keypadKey(at")
    }

    // MARK: Selection — a cell tap reaches `selectCell`, which marks the selection

    func testCellTapRoutesThroughHandleCellTapToSelection() {
        // The board's per-cell gesture must route to the shared handler; a regression that
        // detaches the gesture (or reorders it under a gesture-swallowing modifier) breaks
        // selection silently — the exact #542 failure class.
        XCTAssertTrue(sourceContainsInOrder(
            [".onTapGesture {", "handleCellTap(index)"],
            in: source
        ))
        // The handler must actually ROUTE to the selector — a deleted `selectCell(index)` call
        // would otherwise leave this suite green (Codex P2 on #624).
        XCTAssertTrue(sourceContainsInOrder(
            [
                "private func handleCellTap(_ index: Int)",
                "selectCell(index)",
            ],
            in: handleCellTapBlock
        ))
    }

    func testCellsUseRealGridLayoutInsteadOfVisualOffsets() {
        // `offset` moves pixels without participating in parent layout. Stacking all 81 cells at
        // the same origin and offsetting their drawings made the board look correct while leaving
        // overlapping/stale hit regions. Real row/column stacks give every visible cell its own
        // layout and hit-test frame.
        let gridBlock = try! sourceBlock(
            in: source,
            startingAt: "private func gridCells",
            endingBefore: "private func gridLines"
        )
        XCTAssertTrue(sourceContainsInOrder(
            [
                "VStack(spacing: 0)",
                "ForEach(0..<9",
                "HStack(spacing: 0)",
                "ForEach(0..<9",
                "let index = row * 9 + col",
                ".onTapGesture {",
                "handleCellTap(index)",
            ],
            in: gridBlock
        ))
        XCTAssertFalse(sourceExcludingComments(gridBlock).contains(".offset("))
    }

    func testGivenCellsRefuseSelectionInsteadOfEnablingDeadDigitControls() {
        // Givens are immutable, so selecting one would enable the number bar for a cell that
        // can never change (a silent no-op on tap of a digit). The guard must stay: selection
        // is left unchanged, the existing highlight is cleared, and the refusal is
        // ACKNOWLEDGED with the rejection haptic — with ~40 of 81 cells given, a silent no-op
        // here reads as the whole board ignoring taps.
        XCTAssertTrue(sourceContainsInOrder(
            [
                "guard let gameState, !gameState.isCellGiven(index) else {",
                "selectedIndex = nil",
                "ProtectionHapticFeedback.play(.selectionRejected)",
            ],
            in: selectCellBlock
        ))
        // The acceptance path marks the selection — the exact routing #542 rebuilt.
        XCTAssertTrue(selectCellBlock.contains("selectedIndex = index"))
    }

    // MARK: Digit entry — one predicate drives availability and the dim, in lockstep

    func testDigitButtonsAreGatedByTheSingleCanEnterDigitPredicate() {
        // The native buttons own taps while the simultaneous parent gesture owns scrubs, so one
        // predicate must gate both activation paths and the disabled text colour.
        XCTAssertTrue(source.contains("private var canEnterDigit: Bool"))
        XCTAssertTrue(source.contains("guard !boardIsLocked, let selectedIndex, let gameState else { return false }"))
        XCTAssertTrue(source.contains("case .digit: canEnterDigit"))
        XCTAssertTrue(source.contains(".foregroundStyle(!isAvailable ? LavaStyle.secondaryText : isHighlighted ? Color.white : LavaStyle.primaryText)"))
        XCTAssertTrue(source.contains(".disabled(!isAvailable)"))
        // Both touch and accessibility activation route through the same placement entry point.
        XCTAssertTrue(sourceContainsInOrder(
            ["private func activateKey", "case .digit(let digit):", "enterDigit(digit)"],
            in: source
        ))
    }

    func testNotesModeRequiresAnEmptySelectedCell() throws {
        // Notes are candidates for EMPTY cells; `canEnterDigit` must gate the note toggle on
        // the selected cell being empty so pencil taps never silently no-op.
        XCTAssertTrue(sourceContainsInOrder(
            ["if isNotesMode {", "return gameState.workingBoard[selectedIndex] == 0"],
            in: source
        ))
        // The model refuses notes on filled cells as the backstop (the mutator lives in the
        // kit-side SudokuGameState, an SPM source file the test suite can pin directly).
        let model = try readSource(.sudokuGameState)
        XCTAssertTrue(model.contains("guard !isCellGiven(index), userValues[index] == 0"))
    }

    // MARK: Placement — enterDigit mutates the state and persists it

    func testEnterDigitPlacesOrTogglesAndPersists() {
        let block = enterDigitBlock
        XCTAssertTrue(block.contains("guard var state = gameState, let index = selectedIndex, !boardIsLocked else { return }"))
        XCTAssertTrue(block.contains("state.placeValue(digit, at: index)"))
        XCTAssertTrue(block.contains("state.toggleNote(digit, at: index)"))
        // Resumability depends on persist + republish riding the SAME mutation path: the
        // file-wide check would also match eraseCell's identical call, so both are asserted
        // INSIDE the enterDigit block (Codex P2 on #624) — removing the persist call from the
        // placement path now fails here specifically.
        XCTAssertTrue(block.contains("gameState = state"))
        XCTAssertTrue(block.contains("viewModel.persistSudokuGameState(state)"))
        // Republish THEN persist: both must appear, in that order, on the placement path.
        XCTAssertTrue(sourceContainsInOrder(
            ["gameState = state", "viewModel.persistSudokuGameState(state)"],
            in: block
        ))
    }

    // MARK: Eraser — contextual circular action routes to a REAL clear

    func testContextualEraserClearsTheSelectedValue() {
        XCTAssertTrue(source.contains("(1...9).map(SudokuKeypadKey.digit)"))
        XCTAssertTrue(sourceContainsInOrder(
            [
                "private var canEraseSelectedCell: Bool",
                "gameState.userValues[selectedIndex] != 0",
            ],
            in: source
        ))
        XCTAssertTrue(source.contains("let eraserWidth = SudokuEasterEggLayout.eraserKeyHeight"))
        XCTAssertTrue(source.contains("x: keypadKeyCenterX(forSlot: 4, totalWidth: width)"))
        XCTAssertTrue(source.contains("static let eraserKeyHeight: CGFloat = 44"))
        XCTAssertTrue(source.contains("static let eraserDigitGap: CGFloat = 18"))
        XCTAssertTrue(sourceContainsInOrder(
            [
                "y: SudokuEasterEggLayout.keypadPreviewHeight",
                "- SudokuEasterEggLayout.eraserDigitGap",
                "- SudokuEasterEggLayout.eraserKeyHeight / 2",
            ],
            in: source
        ))
        XCTAssertTrue(source.contains(".accessibilityHidden(!canEraseSelectedCell)"))
        XCTAssertTrue(source.contains(".disabled(!canEraseSelectedCell)"))
        XCTAssertTrue(source.contains("case .eraser:\n            \"Erase selected cell\".lavaLocalized"))
        XCTAssertTrue(sourceContainsInOrder(
            ["case .eraser:", "if let selectedIndex", "eraseCell(at: selectedIndex)"],
            in: source
        ))

        let block = eraseCellBlock
        XCTAssertTrue(block.contains("state.clearCell(at: index)"))
        XCTAssertTrue(block.contains("gameState = state"))
        XCTAssertTrue(block.contains("viewModel.persistSudokuGameState(state)"))
        XCTAssertTrue(sourceContainsInOrder(
            [
                "guard var state = gameState, !boardIsLocked, !state.isCellGiven(index) else { return }",
                "state.clearCell(at: index)",
                "gameState = state",
                "viewModel.persistSudokuGameState(state)",
            ],
            in: block
        ))
    }

    // MARK: Finger tracking — drag is board-local, never digit-placement machinery

    func testFingerTrackingIsScopedToTheFixedBoardFrame() {
        // The tracking gesture belongs between the board's fixed frame and its outer centering
        // frame. That makes local drag coordinates equal board coordinates in every orientation.
        let code = sourceExcludingComments(source)
        XCTAssertTrue(sourceContainsInOrder(
            [
                ".frame(width: side, height: side)",
                ".simultaneousGesture(boardTrackingGesture(side: side))",
                ".frame(maxWidth: .infinity)",
            ],
            in: code
        ))
        XCTAssertEqual(code.components(separatedBy: "DragGesture(").count - 1, 1)
        XCTAssertTrue(code.contains("DragGesture(minimumDistance: 6, coordinateSpace: .local)"))
        XCTAssertTrue(code.contains("SudokuKeypadTouchOverlay("))
        XCTAssertFalse(code.contains("onGeometryChange"))
        XCTAssertFalse(code.contains("draggingDigit"))
    }

    func testFingerTrackingMovesSelectionAndHapticsOncePerCell() {
        let block = try! sourceBlock(
            in: source,
            startingAt: "private func trackCell",
            endingBefore: "private func cellIndex"
        )
        XCTAssertTrue(sourceContainsInOrder(
            [
                "trackingIndex != index",
                "trackingIndex = index",
                "if gameState.isCellGiven(index)",
                "selectedIndex = nil",
                "else",
                "selectedIndex = index",
                "ProtectionHapticFeedback.play(.selectionConfirmed)",
            ],
            in: block
        ))
        XCTAssertTrue(source.contains("isTrackingLocked: trackingIndex == index && isGiven"))
        XCTAssertTrue(source.contains("if isTrackingLocked { return LavaStyle.secondaryText.opacity(0.24) }"))
        XCTAssertTrue(source.contains("if isTrackingLocked { return LavaStyle.secondaryText.opacity(0.72) }"))
        XCTAssertTrue(source.contains("if isGiven { return LavaStyle.secondaryText.opacity(0.10) }"))
    }

    func testKeypadScrubPreviewsHapticsAndCommitsTheLastKey() throws {
        XCTAssertTrue(sourceContainsInOrder(
            [
                "guard trackedKey != key else { return }",
                "trackedKey = key",
                "ProtectionHapticFeedback.play(.selectionChanged)",
                "private func finishKeypadTouch(commit: Bool)",
                "let keyToCommit = trackedKey",
                "trackedKey = nil",
                "if commit, let keyToCommit",
                "activateKey(keyToCommit)",
            ],
            in: keypadTrackingBlock
        ))
        XCTAssertTrue(source.contains("SudokuKeyPreview("))
        XCTAssertTrue(source.contains("keypadBubbleCenterX"))
        XCTAssertTrue(source.contains("tailOffset: anchor - bubbleCenter"))
        XCTAssertTrue(source.contains(".animation(.interactiveSpring(response: 0.14, dampingFraction: 0.88), value: trackedKey)"))
        XCTAssertTrue(source.contains("override func touchesBegan"))
        XCTAssertTrue(source.contains("override func touchesMoved"))
        XCTAssertTrue(source.contains("override func touchesEnded"))
        XCTAssertTrue(source.contains("override func touchesCancelled"))
        XCTAssertTrue(source.contains("onChanged: (CGPoint?) -> Void"))
        XCTAssertTrue(source.contains("onEnded?(inBoundsPoint(from: touches))"))
        XCTAssertTrue(source.contains("onChanged?(inBoundsPoint(from: touches))"))
        XCTAssertTrue(source.contains("bounds.contains(point) else { return nil }"))
        XCTAssertTrue(sourceContainsInOrder(
            [
                "if let point",
                "trackKeypadTouch(atX: point.x, totalWidth: width)",
                "else",
                "trackedKey = nil",
            ],
            in: source
        ))

        let haptics = try readSource(.protectionHapticFeedback)
        XCTAssertTrue(haptics.contains("UISelectionFeedbackGenerator()"))
        XCTAssertTrue(haptics.contains("selectionChangeGenerator.selectionChanged()"))
        XCTAssertTrue(haptics.contains("selectionChangeGenerator.prepare()"))
    }

    // MARK: Notes and correctness presentation

    func testNotesHideOutsidePencilModeAndFlowIntoAThreeColumnGrid() {
        XCTAssertTrue(source.contains("showsNotes: isNotesMode"))
        XCTAssertTrue(source.contains("if showsNotes && value == 0 && !notes.isEmpty"))
        XCTAssertTrue(source.contains("else if showsNotes && !notes.isEmpty"))
        // The grid's shape and size rules live in the pure LavaSecKit policy
        // (`SudokuNotesGridLayoutTests`), so pin the view's delegation and slotting rather than the
        // retired single-row squeeze.
        XCTAssertTrue(source.contains("SudokuNotesGridLayout.rows(for: notes)"))
        XCTAssertTrue(source.contains("SudokuNotesGridLayout.columnCount(forNoteCount: notes.count)"))
        XCTAssertTrue(source.contains("SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: notes.count)"))
        XCTAssertTrue(source.contains(".frame(width: slotWidth, height: cellSize / CGFloat(rows.count))"))
        XCTAssertTrue(source.contains("design: .rounded).italic()"))
        XCTAssertTrue(source.contains("let candidates = isNotesMode ? state.notes[index].sorted() : []"))
    }

    func testSelectedCellNotesHighlightTheirNumberKeys() {
        XCTAssertTrue(sourceContainsInOrder(
            [
                "private func keyIsNoted",
                "isNotesMode",
                "gameState.notes[selectedIndex].contains(digit)",
            ],
            in: source
        ))
        XCTAssertTrue(source.contains("let isHighlighted = isTracked || isNoted"))
        XCTAssertTrue(source.contains(".fill(isHighlighted ? LavaStyle.safeControlGreen : LavaStyle.cardBackground)"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits(isNoted ? .isSelected : [])"))
    }

    func testEyeToggleShowsRemainingCountsAndCorrectnessOutcome() {
        XCTAssertTrue(source.contains("systemName: showsCorrectness ? \"eye\" : \"eye.slash\""))
        XCTAssertTrue(source.contains("if showsCorrectness {"))
        XCTAssertTrue(source.contains("let remaining = key.remainingCount(in: gameState)"))
        XCTAssertTrue(source.contains("Text(\"\\(remaining)\")"))
        XCTAssertTrue(source.contains("guard showsCorrectness else { return valueLabel }"))
        XCTAssertTrue(source.contains("board[index] == state.puzzle.solution[index]"))
        XCTAssertTrue(source.contains("? \"Correctly placed\".lavaLocalized"))
        XCTAssertTrue(source.contains(": \"Misplaced\".lavaLocalized"))
        XCTAssertTrue(source.contains("correctnessOutcomeIndicator"))
        XCTAssertTrue(source.contains("private var correctnessOutcome: Bool?"))
        XCTAssertTrue(source.contains("gameState.userValues[selectedIndex] != 0"))
        XCTAssertTrue(source.contains("systemName: isCorrect ? \"checkmark.circle.fill\" : \"xmark.circle.fill\""))
        XCTAssertTrue(source.contains("isCorrect ? LavaStyle.safeGreen : LavaStyle.lavaOrangeText"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"sudoku-correctness-outcome\")"))
        XCTAssertTrue(source.contains(".frame(minHeight: 36, maxHeight: .infinity)"), "A reserved outcome slot keeps the board still")
    }

    func testUserEntryColorsFollowAssistanceWithoutChangingGivensOrNotes() throws {
        let grid = try sourceBlock(in: source, startingAt: "private func gridCells", endingBefore: "private func gridLines")
        XCTAssertTrue(grid.contains("showsCorrectness: showsCorrectness"))
        XCTAssertTrue(grid.contains("isCorrect: board[index] == gameState.puzzle.solution[index]"))
        let color = try sourceBlock(in: source, startingAt: "private var valueColor: Color", endingBefore: "private struct SudokuNotesGrid")
        XCTAssertTrue(sourceContainsInOrder(
            [
                "guard !isGiven else { return LavaStyle.ink }",
                "guard showsCorrectness else { return LavaStyle.safeGreen }",
                "return isCorrect ? LavaStyle.safeGreen : LavaStyle.lavaOrangeText",
            ],
            in: color
        ))
        let notes = try sourceBlock(in: source, startingAt: "private struct SudokuNotesGrid", endingBefore: "// MARK: - Key preview")
        XCTAssertTrue(notes.contains(".foregroundStyle(LavaStyle.secondaryText)"))
        XCTAssertTrue(notes.contains("design: .rounded).italic()"))
        XCTAssertTrue(source.contains("if isGiven { return LavaStyle.secondaryText.opacity(0.10) }"))
    }

    func testResetAndRefreshUseConfirmationScaffold() {
        XCTAssertTrue(source.contains(".lavaConfirmationAlert { host in"))
        XCTAssertTrue(source.contains("host.alert(\"Reset puzzle?\", isPresented: $isShowingResetConfirmation)"))
        XCTAssertTrue(source.contains(".alert(\"New puzzle\", isPresented: $isShowingRefreshConfirmation)"))
        XCTAssertTrue(source.contains("systemName: \"arrow.counterclockwise\""))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"sudoku-reset\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"sudoku-refresh\")"))
        XCTAssertTrue(sourceContainsInOrder(
            [
                "private func resetCurrentPuzzle()",
                "let state = SudokuGameState(puzzle: puzzle)",
                "gameState = state",
                "viewModel.persistSudokuGameState(state)",
            ],
            in: source
        ))
        XCTAssertTrue(source.contains("isShowingRefreshConfirmation = true"))
        XCTAssertTrue(sourceContainsInOrder(
            ["Button(\"New puzzle\", role: .destructive)", "startFreshPuzzle()"],
            in: source
        ))
    }

    func testUITestRouteStartsFromAFreshDeterministicPuzzle() throws {
        XCTAssertTrue(sourceContainsInOrder(
            [
                "private let initialPuzzleSeed: UInt64?",
                "if let initialPuzzleSeed",
                "viewModel.startFreshSudokuPuzzle(seed: initialPuzzleSeed)",
            ],
            in: source
        ))
        let app = try readSource(.lavaSecApp)
        XCTAssertTrue(app.contains("SudokuEasterEggView(initialPuzzleSeed: 648)"))
    }

    // MARK: Layout — the board must stay usable on short bands

    func testScreenSizingIgnoresOnlyKeyboardInsets() throws {
        let body = try sourceBlock(in: source, startingAt: "var body: some View", endingBefore: "private var boardIsLocked")
        XCTAssertTrue(sourceContainsInOrder(
            [
                "GeometryReader { proxy in",
                ".scrollBounceBehavior(.basedOnSize)",
                ".ignoresSafeArea(.keyboard, edges: .bottom)",
                ".preferredColorScheme(nil)",
            ],
            in: body
        ), "Keyboard avoidance must be disabled on the screen geometry, not just its background")
    }

    func testBoardSideNeverBelowAnUsableFloor() {
        // The clamp must FLOOR at a usable minimum (not just refuse negatives): a bare
        // `max(0, ...)` still yields a zero-area, tap-dead board on short bands.
        XCTAssertTrue(sourceContainsInOrder(
            [
                "private func boardSide(for size: CGSize) -> CGFloat",
                "SudokuEasterEggLayout.minBoardSide",
            ],
            in: source
        ))
        // 297pt = 9 x 33pt cells: the floor itself is asserted so a later edit cannot
        // silently lower it beneath a comfortable touch target. (The constant lives in the
        // app target, invisible to this SPM suite — pin it AS TEXT, like everything else.)
        XCTAssertTrue(source.contains("static let minBoardSide: CGFloat = 297"))
        XCTAssertTrue(source.contains("static let verticalChromeHeight: CGFloat = 256"))
        XCTAssertTrue(source.contains("size.height - SudokuEasterEggLayout.verticalChromeHeight"))
    }

    func testBoardIsScrollHostedWhenTallerThanTheBand() {
        // The ScrollView host + min-height .frame pairing is what lets the floor clamp
        // overflow into scroll instead of clipping. Remove the pairing (or only the host,
        // leaving the modifiers orphaned on the VStack) and a short band crops the number
        // bar — or the board — out of reach, so the HOST is pinned in order, not just the
        // modifiers (Codex round-2 on #624).
        XCTAssertTrue(sourceContainsInOrder(
            [
                "ScrollView {",
                ".frame(minHeight: proxy.size.height, alignment: .center)",
                ".scrollBounceBehavior(.basedOnSize)",
            ],
            in: source
        ))
    }
}
