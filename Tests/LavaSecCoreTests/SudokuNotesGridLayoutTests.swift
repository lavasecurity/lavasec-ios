import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class SudokuNotesGridLayoutTests: XCTestCase {

    func testColumnCountCapsAtThreeWithFourAsBalancedPair() {
        XCTAssertEqual(SudokuNotesGridLayout.columnCount(forNoteCount: 0), 0)
        XCTAssertEqual(SudokuNotesGridLayout.columnCount(forNoteCount: 1), 1)
        XCTAssertEqual(SudokuNotesGridLayout.columnCount(forNoteCount: 2), 2)
        XCTAssertEqual(SudokuNotesGridLayout.columnCount(forNoteCount: 3), 3)
        XCTAssertEqual(SudokuNotesGridLayout.columnCount(forNoteCount: 4), 2)
        for count in 5...9 {
            XCTAssertEqual(SudokuNotesGridLayout.columnCount(forNoteCount: count), 3, "count \(count)")
        }
    }

    func testRowsFlowAscendingRowMajorWithShortFinalRow() {
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: []), [])
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: [5]), [[5]])
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: [3, 1]), [[1, 3]])
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: [9, 2, 7]), [[2, 7, 9]])
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: [4, 2, 3, 1]), [[1, 2], [3, 4]])
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: [5, 3, 1, 7, 9]), [[1, 3, 5], [7, 9]])
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: [6, 5, 4, 3, 2, 1]), [[1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(SudokuNotesGridLayout.rows(for: [1, 2, 3, 4, 5, 6, 7]), [[1, 2, 3], [4, 5, 6], [7]])
        XCTAssertEqual(
            SudokuNotesGridLayout.rows(for: Set(1...9)),
            [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
        )
    }

    func testFontSizeKeepsLoneNoteAtCommittedValueSize() {
        XCTAssertEqual(SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: 1), 0.55, accuracy: 0.0001)
        XCTAssertEqual(SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: 0), 0, accuracy: 0.0001)
    }

    func testFontSizeFitsEachSlotAndNeverExceedsTheCommittedValue() {
        for count in 1...9 {
            XCTAssertLessThanOrEqual(
                SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: count),
                0.55,
                "count \(count) must not exceed the committed-value size"
            )
        }
        // A 3x3 digit must fit a third of the cell (minus padding) yet stay well above the old
        // squeeze floor of 0.18.
        let nine = SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: 9)
        XCTAssertLessThanOrEqual(nine, 1.0 / 3.0)
        XCTAssertGreaterThan(nine, 0.2)
        // A balanced 2x2 block has more room per digit than a 1x3 row.
        XCTAssertGreaterThan(
            SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: 4),
            SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: 3)
        )
    }
}
