import Foundation

/// The resumable progress for one Sudoku round: the underlying `puzzle` plus the player's mutable
/// entries, candidate notes, and a solved flag. Pure and `Codable` so it persists verbatim under the
/// Lava Guard progress toggle and round-trips through `SudokuGameStateTests`.
///
/// `SudokuPuzzle.givens` carries the locked clue cells; `userValues` carries the player's entries in
/// the empty positions (a non-zero `userValues[i]` is only ever allowed where `givens[i] == 0`). The
/// "working board" — what the UI renders and what the solve check evaluates — is the two merged: a
/// given overrides an empty cell, otherwise the user value (or 0 for an as-yet-empty cell).
public struct SudokuGameState: Codable, Equatable, Sendable {
    /// The puzzle being played: clue cells plus the canonical solution. `private(set)` so callers
    /// can't swap in malformed arrays that bypass the validated decoder / initializer — the fixed
    /// 9×9 renderer and mutators index cells 0...80, so a shortened replacement would crash (Codex
    /// review on lavasec-ios#512). Mutations go through the validated `init(from:)` and the mutating
    /// accessors below.
    public private(set) var puzzle: SudokuPuzzle
    /// The player's entries in the non-given cells. `0` means "not yet filled." Same 81-int layout as
    /// `SudokuPuzzle.givens`; a non-zero value at a given cell is ignored (givens are immutable).
    /// `private(set)` — see `puzzle`.
    public private(set) var userValues: [Int]
    /// Candidate digits pencilled into each cell, `1...9`. Independently toggleable per cell and kept
    /// even after a value is placed (placing a value clears that cell's notes — see `placeValue`).
    /// `private(set)` — see `puzzle`.
    public private(set) var notes: [Set<Int>]

    /// `true` exactly when the working board (givens + user values) is fully and correctly filled.
    /// DERIVED, not stored: it is recomputed on demand so it can never disagree with `userValues`, and
    /// no caller can set it to `true` while the board is unfinished (a writable stored flag would let
    /// one forged value discard an in-progress board as "solved" — Codex review on lavasec-ios#512). The UI
    /// uses it to lock the board + tint the reshuffle glyph green once a round is correctly finished.
    public var isSolved: Bool {
        workingBoard == puzzle.solution
    }

    /// `true` exactly when every cell of the working board holds a value (none is still 0). Distinct
    /// from `isSolved`: a fully filled board may still be WRONG (a misplaced digit), which the UI
    /// signals with the orange border ("check your work") while keeping it editable. CHEAP to compute
    /// (one `contains(0)` over 81 ints) so the border re-evaluates per placement without a solver pass.
    public var isComplete: Bool {
        !workingBoard.contains(0)
    }

    /// Creates a fresh, empty-progress state for `puzzle`. `userValues` and `notes` start empty; the
    /// solved state derives from the working board, so `isSolved` reads `false` for an empty board.
    public init(puzzle: SudokuPuzzle) {
        self.puzzle = puzzle
        self.userValues = [Int](repeating: 0, count: 81)
        self.notes = [Set<Int>](repeating: [], count: 81)
    }

    private enum CodingKeys: String, CodingKey {
        case puzzle, userValues, notes
    }

    /// Decodes persisted progress with shape + value validation, THROWING (not trapping) on a
    /// corrupted payload. The synthesized decoder accepts any-length arrays and out-of-range values —
    /// a truncated or older on-disk board would otherwise publish arrays the 9×9 renderer indexes past
    /// 80 and crash (Codex review on lavasec-ios#512). `puzzle` decoding already validates its own two
    /// arrays; here `userValues` must be 81 cells of 0...9 and `notes` must be 81 sets drawn from
    /// 1...9. The loader calls this through `try?`, so a corrupt payload is discarded. `isSolved` is
    /// intentionally NOT decoded — it is derived from the restored working board on every read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let puzzle = try container.decode(SudokuPuzzle.self, forKey: .puzzle)
        let userValues = try container.decode([Int].self, forKey: .userValues)
        let notes = try container.decode([Set<Int>].self, forKey: .notes)
        let validValues = userValues.count == 81 && userValues.allSatisfy { (0...9).contains($0) }
        let validNotes = notes.count == 81 && notes.allSatisfy { $0.allSatisfy { (1...9).contains($0) } }
        guard validValues, validNotes else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "SudokuGameState userValues must be 81 cells of 0...9 and notes must be 81 sets of 1...9"
                )
            )
        }
        self.puzzle = puzzle
        self.userValues = userValues
        self.notes = notes
    }

    /// The merged, player-facing board: a given where present, else the user value, else 0. Indexed
    /// row-major. Used for rendering and the solve check (the working board matching `puzzle.solution`
    /// *and* being full is what "solved" means).
    public var workingBoard: [Int] {
        (0..<81).map { puzzle.givens[$0] != 0 ? puzzle.givens[$0] : userValues[$0] }
    }

    /// `true` if `index` is a clue cell (a given) and therefore not editable by the player. The UI uses
    /// this to refuse selection of givens for value entry or note placement.
    public func isCellGiven(_ index: Int) -> Bool {
        puzzle.givens[index] != 0
    }

    /// Places `digit` at `index`, replacing any value already there (replace-on-tap semantics). Given
    /// cells are immutable — placing into one is a no-op (the UI never offers the action, but the
    /// model defends the invariant regardless). Placing a value clears that cell's notes (a committed
    /// value supersedes its candidates). `isSolved` is derived, so it reflects the new board
    /// immediately.
    public mutating func placeValue(_ digit: Int, at index: Int) {
        guard !isCellGiven(index), (1...9).contains(digit) else { return }
        userValues[index] = digit
        notes[index] = []
    }

    /// Toggles `digit` as a candidate note for `index`. Given cells and cells holding a placed value
    /// are not note-editable — given cells are immutable, and a committed value supersedes candidates
    /// (so the 3×3 mini-grid only renders on empty, non-given cells the player is still considering).
    public mutating func toggleNote(_ digit: Int, at index: Int) {
        guard !isCellGiven(index), userValues[index] == 0, (1...9).contains(digit) else { return }
        if notes[index].contains(digit) {
            notes[index].remove(digit)
        } else {
            notes[index].insert(digit)
        }
    }

    /// Erases the value and all candidate notes at `index`. Given cells are immutable (no-op) so a
    /// stray erase never removes a clue. This is the model behind the toolbar eraser button.
    public mutating func clearCell(at index: Int) {
        guard !isCellGiven(index) else { return }
        userValues[index] = 0
        notes[index] = []
    }

    /// How many more of `digit` (1...9) the player may still place: nine total minus the given and
    /// user-entered occurrences already on the working board. Backs the optional remaining-count
    /// badge under each digit in the bottom number bar (toggle-able, default off).
    public func remainingCount(for digit: Int) -> Int {
        guard (1...9).contains(digit) else { return 0 }
        let placed = workingBoard.lazy.filter { $0 == digit }.count
        return max(0, 9 - placed)
    }
}
