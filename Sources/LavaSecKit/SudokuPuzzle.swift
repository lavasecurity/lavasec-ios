import Foundation

/// A generated Sudoku: the puzzle as presented (with empty cells) and its full solution.
///
/// Pure value type with no UI or persistence dependencies, so it lives in the foundation layer and
/// gets real behavioral tests (`SudokuPuzzleTests`). The two arrays are always 81 ints (row-major,
/// index = `row * 9 + col`); `givens` uses `0` for an empty cell, `solution` is fully filled.
///
/// Generation is deterministic from a `seed` (a `SplitMix64` PRNG), so tests and the fixed demo seed
/// reproduce an exact board. Resumed games do NOT replay the seed: `SudokuGameState` persists the
/// board arrays (`givens`/`solution`) themselves and restores those, so no seed is stored. A puzzle
/// is only emitted once digging proves it has a UNIQUE solution, so the user never faces an
/// ambiguous board.
public struct SudokuPuzzle: Codable, Equatable, Sendable {
    /// The 81-cell puzzle as presented to the player. `0` marks an empty (user-fillable) cell; a
    /// non-zero value is a given (locked). Always 81 ints in row-major order.
    public let givens: [Int]
    /// The 81-cell solved board. Always fully filled with `1...9`. The solve check compares a
    /// candidate-filled board to this.
    public let solution: [Int]

    /// Creates a puzzle from its clue cells and the canonical solution. Enforces the SAME invariants
    /// as the validated decoder (exactly 81 cells, `givens` `0...9`, `solution` `1...9`, every
    /// non-zero given agreeing with its solution cell, a LEGAL solution grid, and a UNIQUE solution)
    /// so a direct programmatic construction can't produce a malformed board the fixed 9×9 renderer
    /// or solver would crash on. Invalid construction traps (precondition) — the throwing path is
    /// `init(from:)`, used for possibly-corrupt persisted payloads. Callers normally use
    /// `generate(seed:)`, which always satisfies these invariants.
    public init(givens: [Int], solution: [Int]) {
        precondition(
            givens.count == 81 && solution.count == 81,
            "SudokuPuzzle requires 81 cells (got givens=\(givens.count), solution=\(solution.count))"
        )
        precondition(
            givens.allSatisfy { (0...9).contains($0) } && solution.allSatisfy { (1...9).contains($0) },
            "SudokuPuzzle givens must be 0...9 and solution must be 1...9"
        )
        precondition(
            zip(givens, solution).allSatisfy { given, solved in given == 0 || given == solved },
            "SudokuPuzzle non-zero givens must agree with their solution cells"
        )
        precondition(
            SudokuPuzzle.solutionIsPermutationGrid(solution),
            "SudokuPuzzle solution must be a legal grid (each row/col/box a permutation of 1...9)"
        )
        precondition(
            SudokuSolver.countSolutions(in: givens, limit: 2) == 1,
            "SudokuPuzzle givens must have exactly one solution"
        )
        self.givens = givens
        self.solution = solution
    }

    /// Shape- and range-only construction for testing the solver's robustness to intentionally
    /// INVALID boards (e.g. duplicate givens the solver must reject as 0 solutions) and for the
    /// game-state tests' minimal fixtures. The public init and `init(from:)` enforce the full
    /// invariants, so a malformed board can never reach the renderer through normal construction —
    /// this bypass is the narrow, explicit escape hatch the solver and game-state tests use, via
    /// `@testable`. Callers should never need it.
    init(shapeAndRangeValidatedGivens givens: [Int], solution: [Int]) {
        precondition(
            givens.count == 81 && solution.count == 81
                && givens.allSatisfy { (0...9).contains($0) }
                && solution.allSatisfy { (1...9).contains($0) },
            "SudokuPuzzle shape+range init requires 81 cells with givens 0...9 and solution 1...9"
        )
        self.givens = givens
        self.solution = solution
    }

    private enum CodingKeys: String, CodingKey {
        case givens, solution
    }

    /// Decodes a persisted puzzle with shape + value validation, THROWING (not trapping) on a
    /// corrupted payload. The synthesized decoder accepts any-length arrays and out-of-range values —
    /// a truncated or older on-disk board would otherwise publish `givens`/`solution` that the 9×9
    /// renderer and solver index past 80 and crash (Codex review on lavasec-ios#512). In addition to shape
    /// and ranges, every non-zero given must AGREE with the solution at the same cell, the `solution`
    /// itself must be a LEGAL Sudoku grid (each row, column, and box a permutation of 1...9), and the
    /// `givens` must have EXACTLY ONE solution (so an ambiguous all-empty / multi-solution payload is
    /// rejected, and that unique solution provably equals the stored `solution` given the agreement
    /// check — the stored legal grid is a solution of the givens, and uniqueness forces it to be THE
    /// solution). A payload failing any of these yields a target the player can never legitimately
    /// reach or is ambiguous, so it is rejected here and a fresh puzzle generated instead. The loader
    /// calls this through `try?`, so a corrupt payload is discarded.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let givens = try container.decode([Int].self, forKey: .givens)
        let solution = try container.decode([Int].self, forKey: .solution)
        let validGivens = givens.count == 81 && givens.allSatisfy { (0...9).contains($0) }
        let validSolution = solution.count == 81 && solution.allSatisfy { (1...9).contains($0) }
        // Only run the solver on boards with the correct shape: the solver's masks/conflict checks
        // index cells 0...80, so a short array must fail validation FIRST (never reach the solver).
        let agreement = validGivens && validSolution
            && zip(givens, solution).allSatisfy { given, solved in given == 0 || given == solved }
        let solutionIsLegalGrid = validSolution && SudokuPuzzle.solutionIsPermutationGrid(solution)
        let hasUniqueSolution = validGivens && SudokuSolver.countSolutions(in: givens, limit: 2) == 1
        guard validGivens, validSolution, agreement, solutionIsLegalGrid, hasUniqueSolution else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "SudokuPuzzle must hold 81 cells with givens 0...9, a legal 1...9 solution grid, every non-zero given agreeing with its solution cell, and a unique solution"
                )
            )
        }
        self.givens = givens
        self.solution = solution
    }

    /// Returns `true` if `board` is a fully filled LEGAL Sudoku grid: every row, column, and 3×3 box
    /// contains each digit 1...9 exactly once. Called by the decoder to reject a persisted solution
    /// that is in-range but invalid (e.g. a duplicated digit from corruption), which would otherwise
    /// become an unreachable/incorrect solve target.
    private static func solutionIsPermutationGrid(_ board: [Int]) -> Bool {
        guard board.count == 81 else { return false }
        let full = Set(1...9)
        for unit in 0..<9 {
            var row = Set<Int>()
            var col = Set<Int>()
            var box = Set<Int>()
            for offset in 0..<9 {
                row.insert(board[unit * 9 + offset])
                col.insert(board[offset * 9 + unit])
                let boxRow = (unit / 3) * 3 + offset / 3
                let boxCol = (unit % 3) * 3 + offset % 3
                box.insert(board[boxRow * 9 + boxCol])
            }
            if row != full || col != full || box != full {
                return false
            }
        }
        return true
    }

    /// The number of clue cells the player starts with (non-zero givens).
    public var givenCount: Int {
        givens.lazy.filter { $0 != 0 }.count
    }

    /// A deterministic generator. The same `seed` always produces the same puzzle, so tests and the
    /// fixed demo seed reproduce an exact board; a resumed game restores the stored arrays instead
    /// of replaying a seed. The clue count is sampled per seed from the `SudokuGeneration`
    /// distribution — or forced to the hidden challenge target when `challenge` is `true` — and
    /// digging guarantees a unique solution: a cell is only removed when the resulting puzzle still
    /// solves to exactly one board.
    public static func generate(seed: UInt64, challenge: Bool = false) -> SudokuPuzzle {
        var rng = SplitMix64(seed: seed)
        let solution = generateFullSolution(using: &rng)
        let target = challenge ? SudokuGeneration.challengeGivenCount : SudokuGeneration.targetGivenCount(using: &rng)
        let givens = digHoles(from: solution, targetGivens: target, using: &rng)
        return SudokuPuzzle(givens: givens, solution: solution)
    }

    /// Counts solutions of the receiver's `givens` board, short-circuiting at `limit`. Used by the
    /// digging pass to assert uniqueness (limit 2 → "at most one extra solution exists") and exposed
    /// for tests. Returns `0` (unsolvable), `1` (unique), or `2` (two-or-more, ambiguous).
    public func solutionCount(limit: Int = 2) -> Int {
        SudokuSolver.countSolutions(in: givens, limit: limit)
    }
}

// MARK: - Generation

/// Difficulty band and distribution for the greedy dig. Kept off the public `SudokuPuzzle` type so
/// the difficulty vocabulary stays engine-internal — callers ask for *a* puzzle, not a level.
private enum SudokuGeneration {
    /// The lowest clue count the greedy dig aims for. 28 is the practical floor for random digging —
    /// below it the dig plateaus and returns a higher count anyway — and far above the 17-clue
    /// theoretical minimum for a unique Sudoku.
    static let minTargetGivenCount = 28
    /// The highest clue count the dig aims for (~the comfortable-medium end the product locked).
    static let maxTargetGivenCount = 40
    /// The clue count the hidden challenge mode digs to. Below 30 is the challenge contract; 28 is
    /// the most aggressive target the greedy dig can reliably reach (it is also the band floor), so
    /// a challenge board is the hardest uniquely-solvable board this generator produces.
    static let challengeGivenCount = 28

    /// Draws a per-seed target clue count from a TRIANGULAR distribution over
    /// `[minTargetGivenCount, maxTargetGivenCount]` with the mode at the midpoint: mostly medium
    /// puzzles, with the easier and harder ends progressively rarer. Sampling as the average of two
    /// uniform draws is the standard sum-of-two-uniforms triangular (mode at the midpoint, tapering
    /// linearly to each end). Deterministic from `rng`, so the same seed still reproduces an exact
    /// board; the Android port reproduces the draws and the rounded arithmetic exactly.
    static func targetGivenCount(using rng: inout SplitMix64) -> Int {
        let lower = Double(minTargetGivenCount)
        let upper = Double(maxTargetGivenCount)
        let first = rng.nextUnitInterval()
        let second = rng.nextUnitInterval()
        return Int((lower + (upper - lower) * (first + second) / 2).rounded())
    }
}

/// A small deterministic PRNG so `generate(seed:)` is reproducible across launches and platforms.
/// `SystemRandomNumberGenerator` is seeded by the OS and would vary run-to-run, so a fixed seed
/// (tests, the demo seed) would no longer reproduce its board. SplitMix64 is a single-value state,
/// has no weak low bits for the small shuffles here, and is sufficient for puzzle scrambling
/// (this is NOT a crypto context).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }

    /// A uniform `Double` in `[0, 1)` drawn from the top 53 bits of one `next()`, matching the
    /// precision `Double.random(in:using:)` uses. Consumed only when sampling the difficulty target;
    /// the Android port reproduces the same value.
    mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// Builds a full, valid solved board. Fills the three diagonal 3×3 boxes first (they share no row or
/// column, so each is an independent permutation of 1...9), then backtracks the remaining cells with a
/// randomized candidate order. The diagonal-box seed guarantees the backtracker always starts from a
/// consistent partial solution and never has to undo its own first moves.
private func generateFullSolution(using rng: inout SplitMix64) -> [Int] {
    var board = [Int](repeating: 0, count: 81)
    for box in 0..<3 {
        let baseRow = box * 3
        let baseCol = box * 3
        var digits = Array(1...9).shuffled(using: &rng)
        for r in 0..<3 {
            for c in 0..<3 {
                board[(baseRow + r) * 9 + (baseCol + c)] = digits.removeLast()
            }
        }
    }
    // A valid Sudoku solution always exists from the three independent diagonal boxes, so the
    // backtracker is guaranteed to return `true`. Asserting it documents that invariant — a `false`
    // would mean the returned board is incomplete and the puzzle's solution would be invalid.
    precondition(SudokuSolver.fillFirstSolution(in: &board, using: &rng), "Sudoku generation must complete a full solution")
    return board
}

/// Removes values from a solved board until `targetGivens` clues remain, committing a removal only
/// when the puzzle keeps a unique solution. Cells are dug in a shuffled order so two boards with the
/// same target produce visibly different puzzles. If digging a particular cell would break uniqueness
/// it is restored and the next candidate is tried; once the target is hit — or every cell has been
/// considered — digging stops. The result always has AT LEAST `targetGivens` clues (digging stops the
/// moment the target is reached; a plateau where no remaining clue can be removed without breaking
/// uniqueness leaves a few extra) and is always uniquely solvable.
private func digHoles(from solution: [Int], targetGivens: Int, using rng: inout SplitMix64) -> [Int] {
    var givens = solution
    var remaining = givens.lazy.filter { $0 != 0 }.count
    let order = Array(0..<81).shuffled(using: &rng)
    for index in order where remaining > targetGivens {
        guard givens[index] != 0 else { continue }
        let removed = givens[index]
        givens[index] = 0
        // A dig is kept only when the puzzle is still uniquely solvable: the solver returning ≤ 1
        // solution. (Returning exactly 1 means unique; 0 is impossible here because the original
        // board was solved, but `≤ 1` is the safe, intention-revealing guard.)
        if SudokuSolver.countSolutions(in: givens, limit: 2) <= 1 {
            remaining -= 1
        } else {
            givens[index] = removed
        }
    }
    return givens
}

// MARK: - Solver

/// Index-based Sudoku solver over a flat 81-int board (0 = empty). Two entry points:
/// - `fillFirstSolution`: backtracking fill that writes the first solution found into the board
///   (used by generation to complete a partial grid); randomized for diversity.
/// - `countSolutions`: counts solutions up to `limit` using minimum-remaining-values (MRV) cell
///   selection, short-circuiting at `limit` (used by the unique-solution gate during digging).
private enum SudokuSolver {
    private static let rows = 0..<9
    private static let boxOf: [Int] = (0..<81).map { index in
        let row = index / 9
        let col = index % 9
        return (row / 3) * 3 + (col / 3)
    }

    /// Fills the first empty cell's worth of a solution into `board`, returning whether a complete
    /// solution was found. Candidate digits are tried in a randomized order so each generation pass
    /// produces a different valid board. The passed `board` is mutated in place and left in a solved
    /// state on success.
    static func fillFirstSolution(in board: inout [Int], using rng: inout SplitMix64) -> Bool {
        guard let cell = nextEmptyCell(in: board) else {
            return true
        }
        for digit in Array(1...9).shuffled(using: &rng) where canPlace(board, digit, at: cell) {
            board[cell] = digit
            if fillFirstSolution(in: &board, using: &rng) {
                return true
            }
            board[cell] = 0
        }
        return false
    }

    /// Counts solutions to `givens` up to `limit`, choosing the empty cell with the fewest legal
    /// candidates at each step (MRV) to prune aggressively and short-circuit fast. Used to assert a
    /// puzzle has a unique solution (limit 2 ⇒ distinguishes 0/1/2+) without enumerating every solve.
    ///
    /// Conflicting givens (the same digit appearing more than once in a single row, column, or box) are
    /// rejected BEFORE the search starts: the bitmask masks would collapse the duplicates into one bit
    /// without marking the board invalid, so a fully filled conflicting grid would be misreported as
    /// having one solution, and a sparse conflicting board would trigger an enormous recursive search
    /// before returning 0. The pre-check returns 0 immediately for any board whose givens violate the
    /// row/col/box uniqueness constraint, keeping the solver honest and fast.
    static func countSolutions(in givens: [Int], limit: Int) -> Int {
        guard !hasConflictingGivens(givens) else {
            return 0
        }

        var board = givens
        var rows = rowMasks(of: board)
        var cols = colMasks(of: board)
        var boxes = boxMasks(of: board)
        return count(&board, rows: &rows, cols: &cols, boxes: &boxes, limit: limit)
    }

    /// Returns `true` if the non-zero givens already violate a row, column, or box uniqueness
    /// constraint — i.e. the same digit appears twice in the same unit. This is the pre-search guard
    /// described in `countSolutions`.
    private static func hasConflictingGivens(_ board: [Int]) -> Bool {
        var seen = [Int](repeating: 0, count: 27) // 9 rows + 9 cols + 9 boxes, one bitmask per unit
        for index in 0..<81 where board[index] != 0 {
            let digit = board[index]
            let row = index / 9
            let col = index % 9
            let box = boxOf[index]
            let bit = 1 << digit
            if (seen[row] & bit) != 0 || (seen[9 + col] & bit) != 0 || (seen[18 + box] & bit) != 0 {
                return true
            }
            seen[row] |= bit
            seen[9 + col] |= bit
            seen[18 + box] |= bit
        }
        return false
    }

    // MARK: First-solution helpers (constraint checks against the in-flight board)

    private static func nextEmptyCell(in board: [Int]) -> Int? {
        board.firstIndex(where: { $0 == 0 })
    }

    private static func canPlace(_ board: [Int], _ digit: Int, at cell: Int) -> Bool {
        let row = cell / 9
        let col = cell % 9
        let box = boxOf[cell]
        for i in 0..<9 {
            if board[row * 9 + i] == digit { return false }
            if board[i * 9 + col] == digit { return false }
        }
        let baseRow = (box / 3) * 3
        let baseCol = (box % 3) * 3
        for r in 0..<3 {
            for c in 0..<3 {
                if board[(baseRow + r) * 9 + (baseCol + c)] == digit { return false }
            }
        }
        return true
    }

    // MARK: Counting solver (bitmask-constrained MRV)

    private static func rowMasks(of board: [Int]) -> [Int] {
        var masks = [Int](repeating: 0, count: 9)
        for row in rows {
            var mask = 0
            for col in 0..<9 {
                let v = board[row * 9 + col]
                if v != 0 { mask |= 1 << v }
            }
            masks[row] = mask
        }
        return masks
    }

    private static func colMasks(of board: [Int]) -> [Int] {
        var masks = [Int](repeating: 0, count: 9)
        for col in 0..<9 {
            var mask = 0
            for row in rows {
                let v = board[row * 9 + col]
                if v != 0 { mask |= 1 << v }
            }
            masks[col] = mask
        }
        return masks
    }

    private static func boxMasks(of board: [Int]) -> [Int] {
        var masks = [Int](repeating: 0, count: 9)
        for index in 0..<81 where board[index] != 0 {
            masks[boxOf[index]] |= 1 << board[index]
        }
        return masks
    }

    private static func count(
        _ board: inout [Int],
        rows: inout [Int],
        cols: inout [Int],
        boxes: inout [Int],
        limit: Int
    ) -> Int {
        // Pick the empty cell with the fewest legal candidates (MRV). Drives the count toward a
        // quick 0 (no candidates → dead branch) or a forced fill, both of which let us hit `limit`
        // sooner and short-circuit. A nil `best` means the board is complete: one solution found.
        guard let cell = fewestCandidatesCell(board, rows: rows, cols: cols, boxes: boxes) else {
            return 1
        }
        let row = cell / 9
        let col = cell % 9
        let box = boxOf[cell]
        let usedMask = rows[row] | cols[col] | boxes[box]
        var total = 0
        for digit in 1...9 where (usedMask & (1 << digit)) == 0 {
            board[cell] = digit
            rows[row] |= 1 << digit
            cols[col] |= 1 << digit
            boxes[box] |= 1 << digit
            total += count(&board, rows: &rows, cols: &cols, boxes: &boxes, limit: limit - total)
            board[cell] = 0
            rows[row] &= ~(1 << digit)
            cols[col] &= ~(1 << digit)
            boxes[box] &= ~(1 << digit)
            if total >= limit {
                return total
            }
        }
        return total
    }

    /// Returns the empty cell index with the fewest legal candidates, or `nil` if the board is full.
    /// Scanning all empty cells on each step is O(81·9) — cheap for a 9×9 grid and exact for MRV,
    /// unlike the first-empty heuristic used by the completion pass (which only needs ONE solution).
    private static func fewestCandidatesCell(
        _ board: [Int],
        rows: [Int],
        cols: [Int],
        boxes: [Int]
    ) -> Int? {
        var best: Int?
        var bestCount = Int.max
        for cell in 0..<81 where board[cell] == 0 {
            let row = cell / 9
            let col = cell % 9
            let box = boxOf[cell]
            let usedMask = rows[row] | cols[col] | boxes[box]
            var candidates = 0
            for digit in 1...9 {
                if (usedMask & (1 << digit)) == 0 {
                    candidates += 1
                }
            }
            if candidates < bestCount {
                bestCount = candidates
                best = cell
                // 0 candidates prunes this whole branch immediately; no need to look further.
                if candidates == 0 { break }
            }
        }
        return best
    }
}
