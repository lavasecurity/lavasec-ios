import Foundation

/// Pure layout rules for a cell's pencilled candidate notes: how many columns the digits flow into
/// and how large each digit renders as the count grows. Kept in `LavaSecKit` (not the view) so the
/// shape table gets executable tests — `SudokuEasterEggView` is an app-target file the package suite
/// can only read as text.
///
/// The grid is capped at three columns and grows toward 3x3 as candidates accumulate. A lone note
/// keeps the committed-value size so it stays as readable as an entry; denser cells shrink each digit
/// to fit its slot. Rows fill left-to-right, top-to-bottom in ascending digit order, and the partial
/// final row stays short so the view can centre it under the full rows above.
public enum SudokuNotesGridLayout {

    /// The number of columns the notes flow into for a given count.
    ///
    /// Three is the cap. Four is deliberately a balanced 2x2 rather than 3 + 1; one or two notes keep
    /// their own single row so they render large and centred.
    public static func columnCount(forNoteCount noteCount: Int) -> Int {
        switch noteCount {
        case ..<1: return 0
        case 1: return 1
        case 2: return 2
        case 4: return 2
        default: return 3
        }
    }

    /// The candidate digits in row-major order, ascending, with the partial final row kept short.
    /// Returns `[]` for an empty set.
    public static func rows(for notes: Set<Int>) -> [[Int]] {
        let digits = notes.sorted()
        guard !digits.isEmpty else { return [] }
        let columns = columnCount(forNoteCount: digits.count)
        return stride(from: 0, to: digits.count, by: columns).map { start in
            Array(digits[start ..< min(start + columns, digits.count)])
        }
    }

    /// The digit size as a multiple of the cell side.
    ///
    /// A lone note matches the committed value (`0.55`, see `SudokuCellView`); a grid shrinks so a
    /// digit fits its slot — bounded by the narrower of the slot width and height, i.e.
    /// `1 / max(columns, rows)` — with the remainder as padding. The one non-monotonic step is four
    /// notes (2x2) sitting above three (1x3): the balanced block genuinely has more room per digit.
    public static func fontSizeMultiple(forNoteCount noteCount: Int) -> Double {
        if noteCount <= 0 { return 0 }
        if noteCount == 1 { return 0.55 }
        let columns = columnCount(forNoteCount: noteCount)
        let rows = Int((Double(noteCount) / Double(columns)).rounded(.up))
        return (1.0 / Double(max(columns, rows))) * 0.82
    }
}
