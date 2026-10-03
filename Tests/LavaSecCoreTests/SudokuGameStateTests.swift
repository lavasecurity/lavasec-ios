import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class SudokuGameStateTests: XCTestCase {
    private func emptyProgress(for puzzle: SudokuPuzzle) -> SudokuGameState {
        SudokuGameState(puzzle: puzzle)
    }

    private func makePuzzle(givens: [Int], solution: [Int] = [Int](repeating: 1, count: 81)) -> SudokuPuzzle {
        // Shape+range-only init: these game-state tests exercise the progress accessors on
        // intentionally minimal boards (the solution array is irrelevant to place/note/erase), so the
        // full-invariant public init (which requires a legal grid + unique solution) would reject them.
        SudokuPuzzle(shapeAndRangeValidatedGivens: givens, solution: solution)
    }

    func testFreshStateStartsEmptyAndUnsolved() {
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81))
        let state = emptyProgress(for: puzzle)

        XCTAssertEqual(state.userValues, [Int](repeating: 0, count: 81))
        XCTAssertTrue(state.notes.allSatisfy { $0.isEmpty })
        XCTAssertFalse(state.isSolved)
    }

    func testPlaceValueSetsUserValueOnEmptyCell() {
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81))
        var state = emptyProgress(for: puzzle)

        state.placeValue(7, at: 0)

        XCTAssertEqual(state.userValues[0], 7)
        XCTAssertEqual(state.workingBoard[0], 7)
    }

    func testPlaceValueIntoGivenCellIsIgnored() {
        var givens = [Int](repeating: 0, count: 81)
        givens[0] = 5
        let puzzle = makePuzzle(givens: givens)
        var state = emptyProgress(for: puzzle)

        state.placeValue(9, at: 0)

        XCTAssertEqual(state.puzzle.givens[0], 5)
        XCTAssertEqual(state.userValues[0], 0)
        XCTAssertEqual(state.workingBoard[0], 5, "the given must win over any user value")
        XCTAssertTrue(state.isCellGiven(0))
    }

    func testPlaceValueReplacesExistingValue() {
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81))
        var state = emptyProgress(for: puzzle)

        state.placeValue(3, at: 4)
        state.placeValue(8, at: 4)

        XCTAssertEqual(state.userValues[4], 8, "placing on a filled cell replaces the value")
        XCTAssertEqual(state.workingBoard[4], 8)
    }

    func testPlaceValueClearsNotesForThatCell() {
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81))
        var state = emptyProgress(for: puzzle)

        state.toggleNote(2, at: 1)
        state.toggleNote(5, at: 1)
        state.placeValue(6, at: 1)

        XCTAssertTrue(state.notes[1].isEmpty, "placing a value supersedes its candidates")
        XCTAssertEqual(state.userValues[1], 6)
    }

    func testToggleNoteAddsAndRemovesCandidate() {
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81))
        var state = emptyProgress(for: puzzle)

        state.toggleNote(4, at: 9)
        XCTAssertTrue(state.notes[9].contains(4))

        state.toggleNote(4, at: 9)
        XCTAssertFalse(state.notes[9].contains(4))
    }

    func testToggleNoteOnGivenCellIsIgnored() {
        var givens = [Int](repeating: 0, count: 81)
        givens[10] = 2
        let puzzle = makePuzzle(givens: givens)
        var state = emptyProgress(for: puzzle)

        state.toggleNote(7, at: 10)
        XCTAssertTrue(state.notes[10].isEmpty)
    }

    func testToggleNoteOnFilledCellIsIgnored() {
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81))
        var state = emptyProgress(for: puzzle)

        state.placeValue(5, at: 0)
        state.toggleNote(3, at: 0)

        XCTAssertTrue(state.notes[0].isEmpty, "a committed value cell is not note-editable")
    }

    func testClearCellRemovesValueAndNotes() {
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81))
        var state = emptyProgress(for: puzzle)

        state.placeValue(4, at: 5)
        state.toggleNote(2, at: 5)
        state.clearCell(at: 5)

        XCTAssertEqual(state.userValues[5], 0)
        XCTAssertTrue(state.notes[5].isEmpty)
        XCTAssertEqual(state.workingBoard[5], 0)
    }

    func testClearCellOnGivenIsIgnored() {
        var givens = [Int](repeating: 0, count: 81)
        givens[5] = 4
        let puzzle = makePuzzle(givens: givens)
        var state = emptyProgress(for: puzzle)

        state.clearCell(at: 5)

        XCTAssertEqual(state.puzzle.givens[5], 4)
        XCTAssertEqual(state.workingBoard[5], 4)
    }

    func testIsSolvedLatchesTrueWhenWorkingBoardMatchesSolution() {
        let solution = SudokuPuzzle.generate(seed: 8).solution
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81), solution: solution)
        var state = emptyProgress(for: puzzle)

        // Fill the working board to the solution by placing the user value in every cell.
        for index in 0..<81 {
            XCTAssertFalse(state.isSolved, "must not be solved before cell \(index) is filled")
            state.placeValue(solution[index], at: index)
        }

        XCTAssertTrue(state.isSolved)

        // `isSolved` is DERIVED, not stored: it must follow the working board and cannot be forged.
        // Clearing any cell un-solves the board; a forged/stored flag could not.
        state.clearCell(at: 0)
        XCTAssertFalse(state.isSolved, "clearing a cell must un-solve a derived isSolved")
    }

    func testIsSolvedStaysFalseForPartialBoard() {
        let solution = SudokuPuzzle.generate(seed: 8).solution
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81), solution: solution)
        var state = emptyProgress(for: puzzle)

        for index in 0..<40 {
            state.placeValue(solution[index], at: index)
        }

        XCTAssertFalse(state.isSolved)
    }

    func testIsCompleteIsTrueOnlyWhenEveryCellHoldsAValue() {
        // An all-empty-givens puzzle lets us fill freely.
        let solution = SudokuPuzzle.generate(seed: 8).solution
        let puzzle = makePuzzle(givens: [Int](repeating: 0, count: 81), solution: solution)
        var state = emptyProgress(for: puzzle)

        XCTAssertFalse(state.isComplete, "an empty board is not complete")

        // Fill 80 of 81 correctly: complete (no zeros) but NOT solved (last cell empty... wait, 80
        // filled leaves one zero, so not complete). Fill the last with a WRONG digit to isolate the
        // "complete but wrong" state.
        for index in 0..<80 {
            state.placeValue(solution[index], at: index)
        }
        XCTAssertFalse(state.isComplete, "one empty cell means not complete")

        // Fill the last cell with a WRONG digit: now complete (no zeros) but wrong (not solved).
        var lastWrong = solution
        lastWrong[80] = solution[80] == 9 ? 1 : solution[80] + 1
        state.placeValue(lastWrong[80], at: 80)
        XCTAssertTrue(state.isComplete, "every cell filled ⇒ complete")
        XCTAssertFalse(state.isSolved, "but the wrong last digit ⇒ not solved")

        // Fix the last cell: complete AND solved.
        state.placeValue(solution[80], at: 80)
        XCTAssertTrue(state.isComplete)
        XCTAssertTrue(state.isSolved)
    }

    func testRemainingCountReflectsGivensPlusUserValues() {
        var givens = [Int](repeating: 0, count: 81)
        givens[0] = 1
        givens[1] = 1
        let puzzle = makePuzzle(givens: givens)
        var state = emptyProgress(for: puzzle)
        state.placeValue(1, at: 2)

        // Two givens + one user value = three 1s placed → six remaining.
        XCTAssertEqual(state.remainingCount(for: 1), 6)
    }

    func testRemainingCountIsZeroForFullyPlacedDigit() {
        var givens = [Int](repeating: 0, count: 81)
        // Scatter nine 4s across distinct rows, cols, and boxes so the working board holds nine of them
        // without validating against Sudoku constraints (remainingCount only tallies, it does not solve).
        let placements = [0, 10, 20, 30, 40, 50, 60, 70, 80]
        for index in placements {
            givens[index] = 4
        }
        let puzzle = makePuzzle(givens: givens)
        let state = emptyProgress(for: puzzle)

        XCTAssertEqual(state.remainingCount(for: 4), 0)
    }

    func testGameStateRoundTripsThroughCodable() throws {
        // Use a REAL generated puzzle (unique-solution givens — the decoder now rejects ambiguous
        // all-empty-givens payloads) and place into a guaranteed non-given cell, so the round-trip
        // isn't seed-dependent on a given's position (placing into a given is a no-op by design).
        let puzzle = SudokuPuzzle.generate(seed: 2026)
        let empties = (0..<81).filter { puzzle.givens[$0] == 0 }
        let emptyCell = try XCTUnwrap(empties.first, "generated puzzle has empty cells")
        // A DIFFERENT guaranteed-empty cell for the notes, so the note round-trip actually exercises
        // encode/decode rather than silently no-oping on a given (Kilo review on lavasec-ios#512).
        let noteCell = try XCTUnwrap(empties.first { $0 != emptyCell }, "generated puzzle has ≥2 empty cells")
        var state = emptyProgress(for: puzzle)
        state.placeValue(3, at: emptyCell)
        state.toggleNote(5, at: noteCell)
        state.toggleNote(8, at: noteCell)

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SudokuGameState.self, from: encoded)

        XCTAssertEqual(state, decoded)
        XCTAssertEqual(decoded.userValues[emptyCell], 3)
        XCTAssertEqual(decoded.notes[noteCell], [5, 8])
    }

    func testDecodeRejectsTruncatedUserValues() throws {
        let puzzle = SudokuPuzzle.generate(seed: 1)
        let state = emptyProgress(for: puzzle)
        let encoded = try JSONEncoder().encode(state)
        // Corrupt the payload: truncate userValues to a 5-element array and attempt decode.
        let data = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var truncated = data
        truncated["userValues"] = [1, 2, 3, 4, 5]
        let bad = try JSONSerialization.data(withJSONObject: truncated)

        XCTAssertThrowsError(try JSONDecoder().decode(SudokuGameState.self, from: bad))

        // An out-of-range userValues value (10, outside 0...9) must be rejected too — the range
        // check applies to userValues independently of the length check and of the puzzle fields.
        var badRange = data
        var values = [Int](repeating: 0, count: 81)
        values[0] = 10
        badRange["userValues"] = values
        let corrupt = try JSONSerialization.data(withJSONObject: badRange)

        XCTAssertThrowsError(try JSONDecoder().decode(SudokuGameState.self, from: corrupt))
    }

    func testDecodeRejectsOutOfRangeNotes() throws {
        let puzzle = SudokuPuzzle.generate(seed: 1)
        let state = emptyProgress(for: puzzle)
        let encoded = try JSONEncoder().encode(state)
        let data = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var bad = data
        // A note set containing 0 (out of the 1...9 domain) is corrupt.
        bad["notes"] = Array(repeating: [0], count: 81)
        let corrupt = try JSONSerialization.data(withJSONObject: bad)

        XCTAssertThrowsError(try JSONDecoder().decode(SudokuGameState.self, from: corrupt))
    }

    func testDecodeRejectsTruncatedNotes() throws {
        let puzzle = SudokuPuzzle.generate(seed: 1)
        let state = emptyProgress(for: puzzle)
        let encoded = try JSONEncoder().encode(state)
        let data = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var bad = data
        // A truncated notes array (5 sets) must be rejected — the exact-81 length check applies to
        // `notes` too.
        bad["notes"] = [[1], [2], [3], [4], [5]]
        let corrupt = try JSONSerialization.data(withJSONObject: bad)

        XCTAssertThrowsError(try JSONDecoder().decode(SudokuGameState.self, from: corrupt))
    }
}
