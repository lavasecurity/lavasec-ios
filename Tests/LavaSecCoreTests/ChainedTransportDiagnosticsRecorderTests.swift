import XCTest

@testable import LavaSecChainedUpstream

/// The rate-bounded emission and cumulative-tally decisions behind the transport telemetry —
/// the provider's sink is a one-line append precisely because everything decidable is here.
final class ChainedTransportDiagnosticsRecorderTests: XCTestCase {
    private func makeRecorder() -> (ChainedTransportDiagnosticsRecorder, SteppableEngineClock) {
        let clock = SteppableEngineClock()
        return (ChainedTransportDiagnosticsRecorder(nowNanoseconds: clock.read), clock)
    }

    func testARebindsDistinctTransitionsAllLogInsideOneSecond() {
        let (recorder, _) = makeRecorder()
        // The rebind marker: old socket cancelled, new socket preparing then ready, all within
        // milliseconds. Every one must produce a line — a name-wide rate bound would log the
        // first and eat the new socket's birth, which is the marker the capture protocol needs.
        let cancelled = recorder.recordTransport(
            channelSequence: 3,
            event: .stateChanged(state: "cancelled", previousState: "ready", previousMilliseconds: 90_000))
        let preparing = recorder.recordTransport(
            channelSequence: 4,
            event: .stateChanged(state: "preparing", previousState: "init", previousMilliseconds: 0))
        let ready = recorder.recordTransport(
            channelSequence: 4,
            event: .stateChanged(state: "ready", previousState: "preparing", previousMilliseconds: 12))

        XCTAssertNotNil(cancelled)
        XCTAssertNotNil(preparing)
        XCTAssertNotNil(ready)
        XCTAssertEqual(ready?.event, "chained-transport-state")
        XCTAssertEqual(ready?.details["channel"], "4")
        XCTAssertEqual(ready?.details["previousMs"], "12")
    }

    func testARepeatedTransitionIsRateBounded() {
        let (recorder, clock) = makeRecorder()
        let flap = ChainedChannelTransportEvent.stateChanged(
            state: "waiting:posix-50", previousState: "ready", previousMilliseconds: 100)
        XCTAssertNotNil(recorder.recordTransport(channelSequence: 1, event: flap))
        XCTAssertNil(
            recorder.recordTransport(channelSequence: 1, event: flap),
            "the SAME transition repeating inside the window is the storm the bound exists for")
        clock.advance(by: 1_000_000_000)
        XCTAssertNotNil(
            recorder.recordTransport(channelSequence: 1, event: flap),
            "the bound is a rate, not a latch — the next second's flap logs again")

        let tallies = recorder.snapshotTallies()
        XCTAssertEqual(
            tallies.stateNotReadyTransitionCount, 3,
            "every observation is tallied whether or not its line was suppressed")
        XCTAssertEqual(tallies.suppressedLogCount, 1, "the suppression itself must be countable")
    }

    func testPressureKindsRateLimitIndependently() {
        let (recorder, _) = makeRecorder()
        XCTAssertNotNil(
            recorder.recordPressure(.outboundQueuePressure(admission: "queued-evicting-1", queueDepth: 256)))
        XCTAssertNil(
            recorder.recordPressure(.outboundQueuePressure(admission: "queued-evicting-1", queueDepth: 256)),
            "an eviction storm is one line per second, not one per shed packet")
        let inbound = recorder.recordPressure(.inboundBacklogRefused(bytes: 1_400))
        XCTAssertNotNil(
            inbound,
            "an outbound storm must not silence the first INBOUND refusal — different "
                + "mechanism, different line")
        XCTAssertEqual(inbound?.details["kind"], "inbound-backlog-refused")
        XCTAssertEqual(recorder.snapshotTallies().pressureEventCount, 3)
    }

    func testTalliesCountTheSignalsTheLivenessLineDifferences() {
        let (recorder, _) = makeRecorder()
        _ = recorder.recordTransport(
            channelSequence: 1,
            event: .viabilityChanged(isViable: false, previousMilliseconds: 40_000))
        _ = recorder.recordTransport(
            channelSequence: 1,
            event: .viabilityChanged(isViable: true, previousMilliseconds: 1_500))
        _ = recorder.recordTransport(channelSequence: 1, event: .sendFailed(error: "posix-50"))
        _ = recorder.recordTransport(channelSequence: 1, event: .receiveLoopEnded(error: "posix-54"))

        let tallies = recorder.snapshotTallies()
        XCTAssertEqual(
            tallies.unviableTransitionCount, 1,
            "only the flip INTO non-viable counts — counting the recovery too would double "
                + "every episode")
        XCTAssertEqual(tallies.sendFailedEdgeCount, 1)
        XCTAssertEqual(tallies.receiveLoopEndedCount, 1)
    }
    func testSuppressionIsTalliedAgainstTheMechanismThatStormed() {
        // One shared counter meant a queue-PRESSURE storm was reported under a channel-shaped
        // name, pointing a reader at the NWConnection when the queue was the problem — the
        // opposite mechanism (Codex P2, PR #582).
        let (recorder, _) = makeRecorder()

        // Two identical pressure emissions inside one rate window: the second is suppressed.
        XCTAssertNotNil(
            recorder.recordPressure(.outboundQueuePressure(admission: "queued-evicting-1", queueDepth: 256)))
        XCTAssertNil(
            recorder.recordPressure(.outboundQueuePressure(admission: "queued-evicting-1", queueDepth: 256)))

        let tallies = recorder.snapshotTallies()
        XCTAssertEqual(
            tallies.suppressedPressureLogCount, 1,
            "a suppressed pressure emission belongs to the pressure tally")
        XCTAssertEqual(
            tallies.suppressedTransportLogCount, 0,
            "and must not be attributed to the channel, which did nothing")
        XCTAssertEqual(
            tallies.suppressedLogCount, 1,
            "the all-kinds total is derived, so it cannot disagree with its parts")
    }
}
