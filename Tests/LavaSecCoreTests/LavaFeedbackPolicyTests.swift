import XCTest
import LavaSecPresentation

final class LavaFeedbackPolicyTests: XCTestCase {
    func testUIOwnedOutcomeTokensCannotRepeatOrReplayAfterWake() {
        var policy = LavaFeedbackPolicy()
        XCTAssertEqual(policy.interaction(.succeeded, control: "solve", value: "a", now: 0, active: true), .succeeded)
        XCTAssertEqual(policy.interaction(.succeeded, control: "solve", value: "b", now: 0, active: true), .succeeded)
        XCTAssertNil(policy.interaction(.succeeded, control: "solve", value: "a", now: 1, active: true))
        XCTAssertNil(policy.interaction(.succeeded, control: "solve", value: "c", now: 1, active: false))
        XCTAssertNil(policy.interaction(.succeeded, control: "solve", value: "c", now: 2, active: true))
    }
    func testTerminalConsumptionAndUnrelatedOperations() {
        var policy = LavaFeedbackPolicy()
        let a = policy.begin("a"), b = policy.begin("b")
        XCTAssertEqual(policy.finish("a", id: a, semantic: .succeeded, active: true), .succeeded)
        XCTAssertNil(policy.finish("a", id: a, semantic: .succeeded, active: true))
        XCTAssertEqual(policy.finish("b", id: b, semantic: .succeeded, active: true), .succeeded)
        let retry = policy.begin("a")
        XCTAssertEqual(policy.finish("a", id: retry, semantic: .succeeded, active: true), .succeeded)
    }
    func testStaleCancelledAndInactiveCannotReplay() {
        var policy = LavaFeedbackPolicy()
        let stale = policy.begin("a"), current = policy.begin("a")
        XCTAssertNil(policy.finish("a", id: stale, semantic: .failed, active: true))
        XCTAssertNil(policy.finish("a", id: current, semantic: .succeeded, active: false))
        XCTAssertNil(policy.finish("a", id: current, semantic: .succeeded, active: true))
        let cancelled = policy.begin("a")
        XCTAssertNil(policy.finish("a", id: cancelled, semantic: .failed, active: true, cancelled: true))
        let automatic = policy.begin("a")
        XCTAssertNil(policy.finish("a", id: automatic, semantic: .succeeded, active: true, origin: .automatic))
    }
    func testSelectionTracksLatestWithoutBacklog() {
        var policy = LavaFeedbackPolicy()
        XCTAssertEqual(policy.interaction(.selected, control: "a", value: "1", now: 0, active: true), .selected)
        XCTAssertNil(policy.interaction(.selected, control: "a", value: "1", now: 1, active: true))
        XCTAssertNil(policy.interaction(.selected, control: "a", value: "2", now: 0.01, active: true))
        XCTAssertNil(policy.interaction(.selected, control: "a", value: "2", now: 1, active: true))
        XCTAssertEqual(policy.interaction(.selected, control: "a", value: "3", now: 1, active: true), .selected)
        XCTAssertEqual(policy.interaction(.selected, control: "b", value: "3", now: 1, active: true), .selected)
        XCTAssertNil(policy.interaction(.selected, control: "b", value: "4", now: 2, active: true, origin: .restoredUI))
    }
}
