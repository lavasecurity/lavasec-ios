import XCTest
import LavaSecAppServices

final class FilterShareabilityMemoTests: XCTestCase {
    func testRepeatedProjectionComputesOnceAndLibraryReplacementRecomputes() {
        var memo = FilterShareabilityMemo()
        var evaluations = 0
        func compute(_ value: Bool) -> Bool { evaluations += 1; return value }
        for _ in 0..<100 {
            XCTAssertTrue(memo.value(for: "same-id", revision: "1", compute: { compute(true) }))
        }
        XCTAssertEqual(evaluations, 1)
        XCTAssertFalse(memo.value(for: "same-id", revision: "2", compute: { compute(false) }))
        XCTAssertEqual(evaluations, 2)
        XCTAssertTrue(memo.value(for: "other-id", revision: "2", compute: { compute(true) }))
        XCTAssertEqual(evaluations, 3)
        memo.reset()
        XCTAssertFalse(memo.value(for: "other-id", revision: "2", compute: { compute(false) }))
        XCTAssertEqual(evaluations, 4)
    }
}
