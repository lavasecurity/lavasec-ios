import XCTest
@testable import LavaSecKit

final class QRScanAttemptTests: XCTestCase {
    func testRetainedReturnAcceptsSameAndDifferentCodesOncePerAttempt() {
        var scanner = QRScanAttempt()
        var deliveries = [String]()
        for value in ["same", "same", "different", "same"] {
            scanner.appear(active: true)
            let token = scanner.generation
            XCTAssertTrue(scanner.receive(value, generation: token) { deliveries.append($0); return true })
            XCTAssertFalse(scanner.receive(value, generation: token) { _ in XCTFail("Duplicate"); return true })
            XCTAssertFalse(scanner.receive("other", generation: token) { _ in XCTFail("Already accepted"); return true })
            scanner.disappear()
            XCTAssertFalse(scanner.receive(value, generation: token) { _ in XCTFail("Hidden"); return true })
        }
        XCTAssertEqual(deliveries, ["same", "same", "different", "same"])
    }

    func testCancellationInvalidInputAndDelayedPermissionAreFenced() {
        var scanner = QRScanAttempt()
        scanner.appear(active: true)
        let cancelled = scanner.generation
        scanner.disappear()
        XCTAssertFalse(scanner.permitsDelivery(generation: cancelled))
        scanner.appear(active: true)
        let token = scanner.generation
        XCTAssertFalse(scanner.receive("", generation: token) { _ in XCTFail(); return true })
        XCTAssertFalse(scanner.receive("unrelated", generation: token) { _ in false })
        XCTAssertFalse(scanner.receive("unrelated", generation: token) { _ in XCTFail("Duplicate frame"); return false })
        XCTAssertTrue(scanner.receive("valid", generation: token) { _ in true })
    }

    func testBackgroundFencesPermissionAndFramesWithoutResettingAcceptance() {
        var scanner = QRScanAttempt()
        scanner.appear(active: true)
        let permission = scanner.generation
        scanner.setActive(false)
        XCTAssertFalse(scanner.permitsDelivery(generation: permission))
        scanner.setActive(true)
        XCTAssertFalse(scanner.permitsDelivery(generation: permission))
        XCTAssertTrue(scanner.receive("valid", generation: scanner.generation) { _ in true })
        scanner.setActive(false)
        scanner.setActive(true)
        XCTAssertFalse(scanner.receive("valid", generation: scanner.generation) { _ in XCTFail(); return true })
        scanner.disappear()
        scanner.setActive(true)
        XCTAssertFalse(scanner.permitsDelivery(generation: scanner.generation))
    }
}
