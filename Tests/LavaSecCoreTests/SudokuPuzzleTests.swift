import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class SudokuPuzzleTests: XCTestCase {
    func testGeneratedBoardIsAValidSolvedGrid() {
        let puzzle = SudokuPuzzle.generate(seed: 1)
        let solution = puzzle.solution

        XCTAssertEqual(solution.count, 81)
        XCTAssertTrue(solution.allSatisfy { (1...9).contains($0) }, "solution must contain only 1...9")

        for unit in rowIndices() + columnIndices() + boxIndices() {
            let values = unit.map { solution[$0] }
            XCTAssertEqual(Set(values).count, 9, "each row/col/box must hold 9 distinct digits")
            XCTAssertEqual(values.reduce(0, +), 45, "a valid unit sums to 45")
        }
    }

    func testGeneratedGivensAreConsistentWithSolution() {
        let puzzle = SudokuPuzzle.generate(seed: 42)
        for index in 0..<81 where puzzle.givens[index] != 0 {
            XCTAssertEqual(
                puzzle.givens[index],
                puzzle.solution[index],
                "a given must match the solved board at the same cell"
            )
        }
    }

    func testGeneratedPuzzleHasUniqueSolution() {
        for seed in [UInt64](arrayLiteral: 1, 7, 99, 1_000, 99_999) {
            let puzzle = SudokuPuzzle.generate(seed: seed)
            XCTAssertEqual(
                puzzle.solutionCount(limit: 2),
                1,
                "seed \(seed): generated puzzle must have a unique solution"
            )
        }
    }

    func testGenerateIsDeterministicForSameSeed() {
        let a = SudokuPuzzle.generate(seed: 1234)
        let b = SudokuPuzzle.generate(seed: 1234)
        XCTAssertEqual(a, b, "the same seed must produce the same puzzle")
    }

    func testGenerateProducesDifferentPuzzlesForDifferentSeeds() {
        let a = SudokuPuzzle.generate(seed: 1)
        let b = SudokuPuzzle.generate(seed: 2)
        XCTAssertNotEqual(a.givens, b.givens, "different seeds should yield visibly different boards")
    }

    func testGivenCountIsWithinDifficultyBand() {
        for seed in [UInt64](arrayLiteral: 3, 500, 50_000) {
            let puzzle = SudokuPuzzle.generate(seed: seed)
            // Digging stops once the target of 40 clues is reached, so a generated puzzle always has
            // AT LEAST 40 clues (greedy digging never overshoots below the target) and, in the rare
            // event every remaining clue would break uniqueness before 40, a few more. The 17-clue
            // theoretical minimum for a unique Sudoku is far below this floor and never a concern.
            XCTAssertGreaterThanOrEqual(
                puzzle.givenCount,
                40,
                "seed \(seed): greedy digging never drops below the 40-clue target"
            )
            XCTAssertLessThanOrEqual(
                puzzle.givenCount,
                50,
                "seed \(seed): a plateau above the target should leave only a few extra clues"
            )
        }
    }

    func testSolutionCountOnEmptyBoardReportsMultipleSolutions() {
        let empty = SudokuPuzzle(shapeAndRangeValidatedGivens: [Int](repeating: 0, count: 81), solution: [Int](repeating: 1, count: 81))
        // An empty grid has many solutions; the counter must short-circuit at the limit of 2.
        XCTAssertGreaterThanOrEqual(empty.solutionCount(limit: 2), 2)
    }

    func testSolutionCountOnUnsolvableBoardIsZero() {
        // Two identical givens in the same row make the board unsolvable.
        var givens = [Int](repeating: 0, count: 81)
        givens[0] = 5
        givens[1] = 5
        let puzzle = SudokuPuzzle(shapeAndRangeValidatedGivens: givens, solution: [Int](repeating: 1, count: 81))
        XCTAssertEqual(puzzle.solutionCount(limit: 2), 0)
    }

    func testSolutionCountOnFullyFilledConflictingBoardIsZero() {
        // A fully filled grid with a duplicate in a row, column, or box is NOT a valid solution — the
        // solver must reject conflicting givens up front rather than misreport one solution. (Without
        // the pre-search conflict check the bitmask masks collapse the duplicate into one bit and a
        // fully filled board reads as "one solution" — the P2 gap this test pins.)
        let solution = SudokuPuzzle.generate(seed: 5).solution
        var conflicting = solution
        // Corrupt the solved board: repeat cell 0's digit into cell 1 (both in row 0).
        conflicting[1] = conflicting[0]
        let puzzle = SudokuPuzzle(shapeAndRangeValidatedGivens: conflicting, solution: solution)
        XCTAssertEqual(puzzle.solutionCount(limit: 2), 0)
    }

    func testSolutionCountOnColumnConflictIsZero() {
        var givens = [Int](repeating: 0, count: 81)
        // Duplicate in the same COLUMN (cells 0 and 9 are both in column 0).
        givens[0] = 3
        givens[9] = 3
        let puzzle = SudokuPuzzle(shapeAndRangeValidatedGivens: givens, solution: [Int](repeating: 1, count: 81))
        XCTAssertEqual(puzzle.solutionCount(limit: 2), 0)
    }

    func testSolutionCountOnBoxConflictIsZero() {
        var givens = [Int](repeating: 0, count: 81)
        // Duplicate in the same 3×3 BOX (cells 0 and 10 are both in the top-left box).
        givens[0] = 7
        givens[10] = 7
        let puzzle = SudokuPuzzle(shapeAndRangeValidatedGivens: givens, solution: [Int](repeating: 1, count: 81))
        XCTAssertEqual(puzzle.solutionCount(limit: 2), 0)
    }

    func testSolverIsFastOnSparseConflictingBoard() {
        // The sparse duplicate fixture must return 0 immediately (the pre-search conflict guard)
        // rather than launch the enormous recursive search a mask-only solver would attempt.
        var givens = [Int](repeating: 0, count: 81)
        givens[0] = 5
        givens[1] = 5
        let puzzle = SudokuPuzzle(shapeAndRangeValidatedGivens: givens, solution: [Int](repeating: 1, count: 81))
        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertEqual(puzzle.solutionCount(limit: 2), 0)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 1.0, "conflict rejection must be near-instant")
    }

    func testDecodeRejectsMalformedPersistedPuzzle() throws {
        let valid = SudokuPuzzle.generate(seed: 3)
        let encoded = try JSONEncoder().encode(valid)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        // A truncated givens array (5 cells) must be rejected rather than decoded into a board the
        // 9×9 renderer would index past 80.
        var truncated = dict
        truncated["givens"] = [1, 2, 3, 4, 5]
        let bad = try JSONSerialization.data(withJSONObject: truncated)
        XCTAssertThrowsError(try JSONDecoder().decode(SudokuPuzzle.self, from: bad))

        // An out-of-range solution value must be rejected too.
        var badValue = dict
        var solution = badValue["solution"] as! [Int]
        solution[0] = 10
        badValue["solution"] = solution
        let badSol = try JSONSerialization.data(withJSONObject: badValue)
        XCTAssertThrowsError(try JSONDecoder().decode(SudokuPuzzle.self, from: badSol))

        // An out-of-range givens value (10, outside 0...9) must be rejected too.
        var badGivensValue = dict
        var givens = badGivensValue["givens"] as! [Int]
        givens[0] = 10
        badGivensValue["givens"] = givens
        let badGivens = try JSONSerialization.data(withJSONObject: badGivensValue)
        XCTAssertThrowsError(try JSONDecoder().decode(SudokuPuzzle.self, from: badGivens))

        // A truncated solution array (5 cells) must be rejected too — the exact-81 length check
        // applies to `solution` as well as `givens`.
        var badShortSolution = dict
        badShortSolution["solution"] = [1, 2, 3, 4, 5]
        let badSolShort = try JSONSerialization.data(withJSONObject: badShortSolution)
        XCTAssertThrowsError(try JSONDecoder().decode(SudokuPuzzle.self, from: badSolShort))
    }

    func testDecodeRejectsGivensThatDisagreeWithSolution() throws {
        let valid = SudokuPuzzle.generate(seed: 4)
        let encoded = try JSONEncoder().encode(valid)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        // A payload whose non-zero given contradicts its solution cell must be rejected: the board
        // could never reach `isSolved`, so the player would be stuck on a corrupted puzzle.
        var bad = dict
        let givenIdx = (bad["givens"] as! [Int]).firstIndex { $0 != 0 }!
        var solution = bad["solution"] as! [Int]
        solution[givenIdx] = solution[givenIdx] == 9 ? 1 : solution[givenIdx] + 1
        bad["solution"] = solution
        let corrupt = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try JSONDecoder().decode(SudokuPuzzle.self, from: corrupt))
    }

    func testDecodeRejectsInvalidSolutionGrid() throws {
        let valid = SudokuPuzzle.generate(seed: 9)
        let encoded = try JSONEncoder().encode(valid)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        // A solution that is in-range but has a duplicated digit in a row is not a legal grid; a
        // player could never legitimately reach it, so it must be rejected. Corrupt an EMPTY cell
        // (not in column 0, so the mutation actually changes it — copying the row's first cell onto a
        // column-0 cell would be a self-copy no-op) to repeat its row's first-cell digit.
        var bad = dict
        var solution = bad["solution"] as! [Int]
        let emptyIdx = (bad["givens"] as! [Int])
            .enumerated().first { $0.element == 0 && $0.offset % 9 != 0 }!.offset
        solution[emptyIdx] = solution[(emptyIdx / 9) * 9] // repeat the row's first cell
        bad["solution"] = solution
        let corrupt = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try JSONDecoder().decode(SudokuPuzzle.self, from: corrupt))
    }

    func testDecodeRejectsAmbiguousGivens() throws {
        let valid = SudokuPuzzle.generate(seed: 11)
        let encoded = try JSONEncoder().encode(valid)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        // An all-empty-givens payload with a legal grid has MANY solutions; restoring it would let the
        // player correctly complete the puzzle differently and never be recognized as solved. The
        // decoder must reject it (unique-solution requirement).
        var bad = dict
        bad["givens"] = [Int](repeating: 0, count: 81)
        let corrupt = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try JSONDecoder().decode(SudokuPuzzle.self, from: corrupt))
    }

    // MARK: Unit index helpers

    private func rowIndices() -> [[Int]] {
        (0..<9).map { row in (0..<9).map { col in row * 9 + col } }
    }

    private func columnIndices() -> [[Int]] {
        (0..<9).map { col in (0..<9).map { row in row * 9 + col } }
    }

    private func boxIndices() -> [[Int]] {
        (0..<9).map { box in
            let baseRow = (box / 3) * 3
            let baseCol = (box % 3) * 3
            return (0..<3).flatMap { r in (0..<3).map { c in (baseRow + r) * 9 + (baseCol + c) } }
        }
    }
}
