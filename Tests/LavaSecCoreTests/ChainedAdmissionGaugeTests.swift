import XCTest

@testable import LavaSecChainedUpstream

/// The producer-side gauge that bounds what may wait for the runner's queue.
final class ChainedAdmissionGaugeTests: XCTestCase {

    func testTheArrivalThatCrossesTheCeilingIsAdmittedAndTheNextIsNot() {
        // Admit-then-saturate is the load-bearing semantic. The arrival that crosses the
        // ceiling is already alive in the caller — refusing it saves no memory, it only drops
        // delivery — so refusal begins with the arrival AFTER the ceiling is met. Fit-checking
        // instead would silently drop any batch larger than the ceiling even into an empty
        // backlog, which is a delivery regression bought with nothing.
        let gauge = ChainedAdmissionGauge(
            limits: .init(maximumBytes: 100, maximumCount: 10))
        XCTAssertTrue(gauge.admit(bytes: 60, units: 1))
        XCTAssertTrue(gauge.admit(bytes: 60, units: 1), "the crossing arrival must be admitted")
        XCTAssertFalse(gauge.admit(bytes: 1, units: 1), "the ceiling was met and nothing was refused")
        XCTAssertEqual(gauge.resident().bytes, 120, "the overshoot is one arrival, no more")
    }

    func testTheCeilingRefusesAtExactlyTheCeiling() {
        // `>=`, not `>`: a backlog holding exactly its ceiling is full. Off by one here is not
        // one stray byte — it is one stray ARRIVAL, of unbounded size.
        let gauge = ChainedAdmissionGauge(
            limits: .init(maximumBytes: 100, maximumCount: 10))
        XCTAssertTrue(gauge.admit(bytes: 100, units: 1))
        XCTAssertFalse(gauge.admit(bytes: 0, units: 1), "a backlog at its ceiling admitted more")
    }

    func testTheCountCeilingBindsWhenArrivalsCarryNoBytes() {
        // The closure is the cost the byte ceiling cannot see: a flood of empty batches or
        // keepalive-sized datagrams admits forever by bytes while the dispatch backlog grows
        // without bound.
        let gauge = ChainedAdmissionGauge(
            limits: .init(maximumBytes: 1_000_000, maximumCount: 3))
        XCTAssertTrue(gauge.admit(bytes: 0, units: 1))
        XCTAssertTrue(gauge.admit(bytes: 0, units: 1))
        XCTAssertTrue(gauge.admit(bytes: 0, units: 1))
        XCTAssertFalse(gauge.admit(bytes: 0, units: 1), "empty arrivals are free closures")
    }

    func testAReleaseRestoresAdmissibility() {
        // Refusal is a level, not a latch. The failure this pins: a gauge that refuses forever
        // once saturated converts one burst into a permanent outbound blackhole that looks
        // exactly like a dead upstream.
        let gauge = ChainedAdmissionGauge(
            limits: .init(maximumBytes: 100, maximumCount: 10))
        XCTAssertTrue(gauge.admit(bytes: 100, units: 1))
        XCTAssertFalse(gauge.admit(bytes: 10, units: 1))
        gauge.release(bytes: 100)
        XCTAssertTrue(gauge.admit(bytes: 10, units: 1), "the backlog drained and the gauge stayed shut")
    }

    func testRefusalsAreTalliedInTheCallersUnits() {
        // A refused BATCH is that many packets a user's device silently did not send. The tally
        // carries the caller's unit so `snapshotCounters()` reads comparably with the queue's
        // shed count, and it lives in the gauge so the refusal and the count cannot disagree.
        let gauge = ChainedAdmissionGauge(
            limits: .init(maximumBytes: 1, maximumCount: 10))
        XCTAssertTrue(gauge.admit(bytes: 1, units: 1))
        XCTAssertFalse(gauge.admit(bytes: 1, units: 5))
        XCTAssertFalse(gauge.admit(bytes: 1, units: 3))
        XCTAssertEqual(gauge.refusedUnitCount(), 8)
        gauge.release(bytes: 1)
        XCTAssertEqual(gauge.refusedUnitCount(), 8, "a release rewrote history")
    }
}
