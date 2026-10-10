import XCTest
import LavaSecPresentation

final class PresentationRevealGateTests: XCTestCase {
    func testColdRootAndRetainedSheetMustBothCommit() {
        var gate = PresentationRevealGate()
        gate.mount("root"); gate.mount("sheet")
        gate.acknowledge("root", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
        gate.acknowledge("sheet", token: gate.token, authorized: true)
        XCTAssertFalse(gate.required)
    }

    func testOldOrUnauthorizedFramesCannotRevealAfterBackground() {
        var gate = PresentationRevealGate()
        gate.mount("root")
        let old = gate.token
        gate.conceal()
        gate.acknowledge("root", token: old, authorized: true)
        gate.acknowledge("root", token: gate.token, authorized: false)
        gate.acknowledge("unknown", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
        gate.acknowledge("root", token: gate.token, authorized: true)
        XCTAssertFalse(gate.required)
    }

    func testDismissedSheetCannotStrandOrReleaseReplacement() {
        var gate = PresentationRevealGate()
        gate.mount("root"); gate.mount("old")
        gate.acknowledge("root", token: gate.token, authorized: true)
        gate.mount("replacement"); gate.unmount("old")
        gate.acknowledge("old", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
        gate.unmount("replacement")
        XCTAssertFalse(gate.required)
    }

    func testOrdinaryNewSheetDoesNotRelockTheApp() {
        var gate = PresentationRevealGate()
        gate.mount("root")
        gate.acknowledge("root", token: gate.token, authorized: true)
        gate.mount("sheet")
        XCTAssertFalse(gate.required)
        gate.conceal()
        gate.acknowledge("root", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
    }
}
