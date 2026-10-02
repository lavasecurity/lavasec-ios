import XCTest

@testable import LavaSecChainedUpstream

/// The telemetry-only derivation of transport events — state timing, viability timing, and the
/// send-failure edge. The `NWConnection` glue in `ChainedUpstreamChannel` cannot be unit-tested
/// (a real connection decides when handlers fire), which is exactly why the derivation lives in
/// this observer and stays decision-free there.
final class ChainedChannelTransportObserverTests: XCTestCase {
    private final class RecordedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(sequence: Int, event: ChainedChannelTransportEvent)] = []
        var all: [(sequence: Int, event: ChainedChannelTransportEvent)] { lock.withLock { storage } }
        var events: [ChainedChannelTransportEvent] { lock.withLock { storage.map(\.event) } }
        func record(_ sequence: Int, _ event: ChainedChannelTransportEvent) {
            lock.withLock { storage.append((sequence, event)) }
        }
    }

    private func makeObserver(
        sequence: Int = 7
    ) -> (ChainedChannelTransportObserver, RecordedEvents, SteppableEngineClock) {
        let recorded = RecordedEvents()
        let clock = SteppableEngineClock()
        let observer = ChainedChannelTransportObserver(
            channelSequence: sequence,
            emit: { recorded.record($0, $1) },
            nowNanoseconds: clock.read)
        return (observer, recorded, clock)
    }

    func testAStateTransitionCarriesTheTimeSpentInThePreviousState() {
        let (observer, recorded, clock) = makeObserver()
        observer.noteState("ready")
        clock.advance(by: 1_800_000_000)
        observer.noteState("waiting:posix-50")

        XCTAssertEqual(
            recorded.events,
            [
                .stateChanged(state: "ready", previousState: "init", previousMilliseconds: 0),
                .stateChanged(
                    state: "waiting:posix-50", previousState: "ready",
                    previousMilliseconds: 1_800),
            ],
            "the waiting line must carry how long the socket had been ready — the stall's "
                + "duration is the whole point of observing the transition")
        XCTAssertEqual(recorded.all.map(\.sequence), [7, 7], "events must name their channel")
    }

    func testARepeatedStateIsNotATransition() {
        let (observer, recorded, clock) = makeObserver()
        observer.noteState("ready")
        clock.advance(by: 500_000_000)
        observer.noteState("ready")

        XCTAssertEqual(
            recorded.events.count, 1,
            "a re-delivered state must not read as a fresh transition with a reset clock")
    }

    func testViabilityFlipsCarryDurationAndDeduplicate() {
        let (observer, recorded, clock) = makeObserver()
        observer.noteViability(true)
        XCTAssertTrue(recorded.events.isEmpty, "born viable — a repeated true is not a flip")

        clock.advance(by: 2_000_000_000)
        observer.noteViability(false)
        clock.advance(by: 1_200_000_000)
        observer.noteViability(false)
        observer.noteViability(true)

        XCTAssertEqual(
            recorded.events,
            [
                .viabilityChanged(isViable: false, previousMilliseconds: 2_000),
                .viabilityChanged(isViable: true, previousMilliseconds: 1_200),
            ],
            "the return to viable must carry the non-viable interval — that number IS the "
                + "invisible stall the investigation is trying to measure")
    }

    func testSendFailuresAreEdgeTriggered() {
        let (observer, recorded, _) = makeObserver()
        observer.noteSendOutcome(error: nil)
        observer.noteSendOutcome(error: "posix-50")
        observer.noteSendOutcome(error: "posix-50")
        observer.noteSendOutcome(error: "posix-50")

        XCTAssertEqual(
            recorded.events, [.sendFailed(error: "posix-50")],
            "a dead socket fails every send at line rate; the edge is the event, the volume "
                + "is the runner's counter")

        observer.noteSendOutcome(error: nil)
        observer.noteSendOutcome(error: "posix-65")
        XCTAssertEqual(
            recorded.events.count, 2,
            "a success re-arms the edge, so the NEXT failure episode is visible too")
    }

    func testProductionObserversClaimDistinctChannelSequences() {
        let recorded = RecordedEvents()
        let first = ChainedChannelTransportObserver(emit: { recorded.record($0, $1) })
        let second = ChainedChannelTransportObserver(emit: { recorded.record($0, $1) })
        XCTAssertNotEqual(
            first.channelSequence, second.channelSequence,
            "two sockets sharing a sequence would make a rebind's old/new lifecycles "
                + "indistinguishable in the log")
        XCTAssertGreaterThan(
            second.channelSequence, first.channelSequence,
            "sequences must be ordered so 'a NEW sequence appeared' reads as 'a socket was "
                + "built after that one'")
    }
}
