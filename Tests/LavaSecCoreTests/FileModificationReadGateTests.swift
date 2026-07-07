import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FileModificationReadGateTests: XCTestCase {
    func testShouldReadOnlyWhenModificationDateChanges() {
        let firstDate = Date(timeIntervalSinceReferenceDate: 100)
        let secondDate = Date(timeIntervalSinceReferenceDate: 200)
        var gate = FileModificationReadGate()

        XCTAssertFalse(gate.shouldRead(modifiedAt: nil))
        XCTAssertTrue(gate.shouldRead(modifiedAt: firstDate))

        gate.markRead(modifiedAt: firstDate)
        XCTAssertFalse(gate.shouldRead(modifiedAt: firstDate))
        XCTAssertTrue(gate.shouldRead(modifiedAt: secondDate))
        XCTAssertTrue(gate.shouldRead(modifiedAt: firstDate, force: true))

        gate.reset()
        XCTAssertTrue(gate.shouldRead(modifiedAt: firstDate))
    }
}
