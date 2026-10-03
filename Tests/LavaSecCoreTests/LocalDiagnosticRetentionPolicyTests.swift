import Foundation
import XCTest
@testable import LavaSecKit

final class LocalDiagnosticRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func entry(_ id: String, age: Double = 0, bytes: Int = 1) -> LocalDiagnosticRetentionPolicy.Entry {
        .init(id: id, receivedAt: now.addingTimeInterval(-age), bytes: bytes)
    }
    private func retained(_ entries: [LocalDiagnosticRetentionPolicy.Entry], count: Int = 64,
                          bytes: Int = 20, reportBytes: Int = 5) -> Set<String> {
        LocalDiagnosticRetentionPolicy.retainedIDs(entries, now: now, maxAge: 14 * 86400,
            maxCount: count, maxBytes: bytes, maxReportBytes: reportBytes)
    }
    func testAgeBoundaryAndFutureClock() {
        XCTAssertEqual(retained([entry("old", age: 14 * 86400 + 1),
            entry("boundary", age: 14 * 86400), entry("future", age: -10)]), ["boundary", "future"])
    }
    func testNewestWinsCountLimitAndTiesAreDeterministic() {
        XCTAssertEqual(retained([entry("old", age: 1), entry("b"), entry("a")], count: 1), ["a"])
    }
    func testTotalAndIndividualByteBounds() {
        // Isolate the per-report cap: with a generous total budget only `maxReportBytes`
        // can reject `oversized`, so deleting that guard fails this assertion (Kilo, PR #781).
        XCTAssertEqual(retained([entry("oversized", bytes: 6), entry("ok", bytes: 5)],
            bytes: 100), ["ok"])
        XCTAssertEqual(retained([entry("oversized", bytes: 6), entry("a", bytes: 5),
            entry("b", bytes: 5), entry("c", bytes: 1)], bytes: 10), ["a", "b"])
        XCTAssertEqual(retained([entry("a", bytes: 5), entry("b", bytes: 4),
            entry("c", bytes: 1)], bytes: 6), ["a", "c"])
    }
    func testDuplicateDoesNotConsumeBudgetAndInvalidSizeIsRejected() {
        XCTAssertEqual(retained([entry("a", bytes: 5), entry("a", bytes: 5),
            entry("b", bytes: 5), entry("invalid", bytes: -1)], count: 2, bytes: 10), ["a", "b"])
        XCTAssertTrue(retained([entry("a")], count: 0).isEmpty)
    }
}
