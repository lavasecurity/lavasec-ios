import XCTest
@testable import LavaSecCore

final class LatencyTraceTests: XCTestCase {
    func testEventsCarryOperationIDForCrossProcessPropagation() {
        let operationID = LatencyOperationID(rawValue: "op-vpn-turn-on-0001")
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 1_000))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: operationID, clock: clock, sink: sink)

        trace.record("tap.received", details: ["action": "turnProtectionOn"])
        let span = trace.beginSpan("vpn.start")
        clock.advance(milliseconds: 42)
        span.end(details: ["result": "connected"])

        XCTAssertEqual(trace.operationID, operationID)
        XCTAssertEqual(sink.events.map(\.operationID), [operationID, operationID, operationID])
        XCTAssertEqual(sink.events.map(\.phase), [.instant, .begin, .end])
    }

    func testNestedSpansRecordParentChildRelationshipAndDurations() throws {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 2_000))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-refresh-0001"), clock: clock, sink: sink)

        let root = trace.beginSpan("refreshLists")
        clock.advance(milliseconds: 100)
        let child = trace.beginSpan("snapshot.reload", parent: root)
        clock.advance(milliseconds: 25)
        child.end()
        clock.advance(milliseconds: 75)
        root.end()

        XCTAssertEqual(sink.events.map(\.phase), [.begin, .begin, .end, .end])

        let rootBegin = sink.events[0]
        let childBegin = sink.events[1]
        let childEnd = sink.events[2]
        let rootEnd = sink.events[3]

        XCTAssertNil(rootBegin.parentSpanID)
        XCTAssertEqual(try XCTUnwrap(rootBegin.spanID), root.spanID)
        XCTAssertEqual(try XCTUnwrap(childBegin.parentSpanID), root.spanID)
        XCTAssertEqual(try XCTUnwrap(childEnd.parentSpanID), root.spanID)
        XCTAssertEqual(try XCTUnwrap(rootEnd.spanID), root.spanID)
        XCTAssertNotEqual(root.spanID, child.spanID)
        XCTAssertEqual(try XCTUnwrap(childEnd.durationMilliseconds), 25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rootEnd.durationMilliseconds), 200, accuracy: 0.001)
    }

    func testDetailsRedactSensitiveKeysAndValues() throws {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 3_000))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-dns-0001"), clock: clock, sink: sink)

        trace.record(
            "resolver.finished",
            details: [
                "domain": "private-bank.example",
                "hostname": "mail.secret.example",
                "url": "https://private-bank.example/login?token=abc",
                "clientIPAddress": "192.168.0.4",
                "authToken": "Bearer abc123",
                "reason": "lookup private-bank.example via 2001:db8::1",
                "authorizationHeader": "authorization: Token abc123",
                "apiKeyHeader": "apiKey=abc123",
                "jwt": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature",
                "cacheResult": "hit",
                "attempt": "2"
            ]
        )

        let details = try XCTUnwrap(sink.events.first?.details)

        XCTAssertEqual(details["cacheResult"], "hit")
        XCTAssertEqual(details["attempt"], "2")
        XCTAssertEqual(details["domain"], "[redacted]")
        XCTAssertEqual(details["hostname"], "[redacted]")
        XCTAssertEqual(details["url"], "[redacted]")
        XCTAssertEqual(details["clientIPAddress"], "[redacted]")
        XCTAssertEqual(details["authToken"], "[redacted]")
        XCTAssertEqual(details["reason"], "[redacted]")
        XCTAssertEqual(details["authorizationHeader"], "[redacted]")
        XCTAssertEqual(details["apiKeyHeader"], "[redacted]")
        XCTAssertEqual(details["jwt"], "[redacted]")

        let serializedDetails = details
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        XCTAssertFalse(serializedDetails.contains("private-bank.example"))
        XCTAssertFalse(serializedDetails.contains("secret.example"))
        XCTAssertFalse(serializedDetails.contains("https://"))
        XCTAssertFalse(serializedDetails.contains("192.168.0.4"))
        XCTAssertFalse(serializedDetails.contains("2001:db8"))
        XCTAssertFalse(serializedDetails.contains("Bearer"))
        XCTAssertFalse(serializedDetails.contains("abc123"))
        XCTAssertFalse(serializedDetails.contains("eyJ"))
    }

    func testDetailsRedactSensitiveDynamicKeys() throws {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 3_250))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-dynamic-key-0001"), clock: clock, sink: sink)

        trace.record("resolver.finished", details: [
            "private-bank.example": "hit",
            "https://secret.example/login": "queued",
            "192.168.0.4": "resolver",
            "safeCount": "3"
        ])

        let details = try XCTUnwrap(sink.events.first?.details)
        let serializedDetails = details
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        XCTAssertEqual(details["safeCount"], "3")
        XCTAssertNil(details["private-bank.example"])
        XCTAssertNil(details["https://secret.example/login"])
        XCTAssertNil(details["192.168.0.4"])
        XCTAssertTrue(details.keys.contains { $0.hasPrefix("redactedDetail") })
        XCTAssertFalse(serializedDetails.contains("private-bank.example"))
        XCTAssertFalse(serializedDetails.contains("secret.example"))
        XCTAssertFalse(serializedDetails.contains("192.168.0.4"))
    }

    func testDetailsDoNotRedactSafeKeysThatOnlyContainSensitiveLetters() throws {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 3_500))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-safe-details-0001"), clock: clock, sink: sink)

        trace.record("snapshot.reuse", details: [
            "skipCache": "false",
            "receiptCount": "3",
            "source": "preparedSnapshot"
        ])

        let details = try XCTUnwrap(sink.events.first?.details)

        XCTAssertEqual(details["skipCache"], "false")
        XCTAssertEqual(details["receiptCount"], "3")
        XCTAssertEqual(details["source"], "preparedSnapshot")
    }

    func testAggregationComputesNearestRankP50AndP95FromCompletedDurationsOnly() throws {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 4_000))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-provider-message-0001"), clock: clock, sink: sink)

        trace.record("provider.message", details: ["state": "queued"])
        for duration in [100.0, 200.0, 300.0, 400.0, 500.0] {
            let span = trace.beginSpan("provider.message")
            clock.advance(milliseconds: duration)
            span.end()
        }

        let summary = try XCTUnwrap(
            LatencyEventAggregation.completedDurationPercentiles(from: sink.events, name: "provider.message")
        )

        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.p50Milliseconds, 300, accuracy: 0.001)
        XCTAssertEqual(summary.p95Milliseconds, 500, accuracy: 0.001)
    }

    func testSpanDurationUsesMonotonicClockWhenWallClockMovesBackward() throws {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 6_000))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-monotonic-0001"), clock: clock, sink: sink)

        let span = trace.beginSpan("vpn.start")
        clock.advance(milliseconds: 250)
        clock.moveWallClockBackward(seconds: 60)
        span.end()

        let endEvent = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(try XCTUnwrap(endEvent.durationMilliseconds), 250, accuracy: 0.001)
    }

    func testEndingSpanMoreThanOnceRecordsOnlyFirstEndEvent() {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 7_000))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-single-end-0001"), clock: clock, sink: sink)

        let span = trace.beginSpan("provider.message")
        clock.advance(milliseconds: 10)
        span.end()
        clock.advance(milliseconds: 90)
        span.end()

        XCTAssertEqual(sink.events.filter { $0.phase == .end }.count, 1)
        XCTAssertEqual(sink.events.last?.durationMilliseconds, 10)
    }

    func testSinkRecordsInstantBeginAndEndEventsInOrder() {
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 5_000))
        let sink = RecordingLatencyEventSink()
        let trace = LatencyTrace(operationID: LatencyOperationID(rawValue: "op-sink-0001"), clock: clock, sink: sink)

        trace.record("action.received", details: ["action": "pause"])
        let span = trace.beginSpan("pauseProtection", details: ["source": "button"])
        clock.advance(milliseconds: 12)
        span.end(details: ["result": "accepted"])

        XCTAssertEqual(sink.events.map(\.name), ["action.received", "pauseProtection", "pauseProtection"])
        XCTAssertEqual(sink.events.map(\.phase), [.instant, .begin, .end])
        XCTAssertEqual(sink.events[0].details["action"], "pause")
        XCTAssertEqual(sink.events[1].details["source"], "button")
        XCTAssertEqual(sink.events[2].details["result"], "accepted")
        XCTAssertEqual(sink.events[0].timestamp, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(sink.events[2].timestamp, Date(timeIntervalSince1970: 5_000.012))
    }

    func testDebugLogDetailsUseParserAllowlistedLatencyKeys() throws {
        let operationID = LatencyOperationID(rawValue: "op-debug-log-0001")
        let parentSpanID = LatencySpanID(rawValue: "span-parent")
        let spanID = LatencySpanID(rawValue: "span-child")
        let event = LatencyEvent(
            operationID: operationID,
            timestamp: Date(timeIntervalSince1970: 8_000),
            name: "tunnel.snapshotLoad",
            phase: .end,
            spanID: spanID,
            parentSpanID: parentSpanID,
            durationMilliseconds: 42.4,
            details: [
                "status": "ok",
                "private.example": "must-not-leak"
            ]
        )

        let details = event.debugLogDetails(operationKind: "turnOn", sequence: 7)

        XCTAssertEqual(details["operationID"], operationID.rawValue)
        XCTAssertEqual(details["operationKind"], "turnOn")
        XCTAssertEqual(details["spanID"], spanID.rawValue)
        XCTAssertEqual(details["parentSpanID"], parentSpanID.rawValue)
        XCTAssertEqual(details["spanName"], "tunnel.snapshotLoad")
        XCTAssertEqual(details["spanEvent"], "end")
        XCTAssertEqual(details["durationMs"], "42")
        XCTAssertEqual(details["sequence"], "7")
        XCTAssertEqual(details["status"], "ok")
        XCTAssertNil(details["private.example"])
        XCTAssertTrue(details.keys.contains { $0.hasPrefix("redactedDetail") })
    }

    func testDebugLogEventSinkWritesLatencySpanEventsWithOperationKindAndSequence() throws {
        var appendedEvents: [(event: String, details: [String: String])] = []
        let sink = LatencyDebugLogEventSink(operationKind: "turnOn") { event, details in
            appendedEvents.append((event, details))
        }
        let clock = FakeLatencyClock(now: Date(timeIntervalSince1970: 9_000))
        let trace = LatencyTrace(
            operationID: LatencyOperationID(rawValue: "op-debug-sink-0001"),
            clock: clock,
            sink: sink,
            spanIDGenerator: { LatencySpanID(rawValue: "span-debug-sink") }
        )

        let span = trace.beginSpan("vpn.start", details: ["status": "begin"])
        clock.advance(milliseconds: 12)
        span.end(details: ["status": "connected"])

        XCTAssertEqual(appendedEvents.map(\.event), ["latency-span-begin", "latency-span-end"])
        XCTAssertEqual(appendedEvents[0].details["operationID"], "op-debug-sink-0001")
        XCTAssertEqual(appendedEvents[0].details["operationKind"], "turnOn")
        XCTAssertEqual(appendedEvents[0].details["spanID"], "span-debug-sink")
        XCTAssertEqual(appendedEvents[0].details["spanName"], "vpn.start")
        XCTAssertEqual(appendedEvents[0].details["spanEvent"], "begin")
        XCTAssertEqual(appendedEvents[0].details["sequence"], "1")
        XCTAssertEqual(appendedEvents[0].details["status"], "begin")
        XCTAssertEqual(appendedEvents[1].details["durationMs"], "12")
        XCTAssertEqual(appendedEvents[1].details["sequence"], "2")
        XCTAssertEqual(appendedEvents[1].details["status"], "connected")
    }

    func testDebugLogEventSinkRedactsDetailsBeforeAppend() throws {
        var appendedDetails: [[String: String]] = []
        let sink = LatencyDebugLogEventSink { _, details in
            appendedDetails.append(details)
        }
        let trace = LatencyTrace(
            operationID: LatencyOperationID(rawValue: "op-redacted-debug-sink-0001"),
            sink: sink
        )

        trace.record("dns.firstDecision", details: [
            "domain": "private.example",
            "url": "https://private.example/path",
            "resolver": "system",
            "decision": "blocked"
        ])

        let details = try XCTUnwrap(appendedDetails.first)
        XCTAssertEqual(details["resolver"], "system")
        XCTAssertEqual(details["decision"], "blocked")
        XCTAssertEqual(details["domain"], "[redacted]")
        XCTAssertEqual(details["url"], "[redacted]")
        XCTAssertFalse(details.values.joined(separator: " ").contains("private.example"))
    }
}

private final class FakeLatencyClock: LatencyClock, @unchecked Sendable {
    private(set) var now: Date
    private(set) var monotonicTime: TimeInterval = 0

    init(now: Date) {
        self.now = now
    }

    func advance(milliseconds: TimeInterval) {
        now = now.addingTimeInterval(milliseconds / 1_000)
        monotonicTime += milliseconds / 1_000
    }

    func moveWallClockBackward(seconds: TimeInterval) {
        now = now.addingTimeInterval(-seconds)
    }
}

private final class RecordingLatencyEventSink: LatencyEventSink, @unchecked Sendable {
    private(set) var events: [LatencyEvent] = []

    func record(_ event: LatencyEvent) {
        events.append(event)
    }
}
