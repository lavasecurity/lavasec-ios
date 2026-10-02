import Foundation
import LavaSecCore
import XCTest

final class RepeatedEventSuppressorTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    /// The FIRST occurrence always emits. A one-off failure is the sample a capture most needs,
    /// and waiting to see whether it repeats would lose it entirely.
    func testAFirstOccurrenceAlwaysEmits() {
        let suppressor = RepeatedEventSuppressor(minimumInterval: 30)

        XCTAssertEqual(suppressor.admit("a", now: start), .emit(suppressedRepeats: 0, suppressedWeight: 0))
        XCTAssertEqual(
            suppressor.admit("b", now: start), .emit(suppressedRepeats: 0, suppressedWeight: 0),
            "a different key has its own timeline — suppressing one must not silence another")
    }

    /// Repeats inside the interval are counted, not dropped: the next emit reports how many
    /// were folded into it, so a reader can tell one failure from five hundred.
    func testSuppressedRepeatsAreCountedAndReportedOnTheNextEmit() {
        let suppressor = RepeatedEventSuppressor(minimumInterval: 30)
        XCTAssertEqual(suppressor.admit("a", now: start), .emit(suppressedRepeats: 0, suppressedWeight: 0))

        for second in 1...5 {
            XCTAssertEqual(
                suppressor.admit("a", now: start.addingTimeInterval(Double(second))), .suppress)
        }

        XCTAssertEqual(
            suppressor.admit("a", now: start.addingTimeInterval(30)),
            .emit(suppressedRepeats: 5, suppressedWeight: 5),
            "the interval is inclusive, and the emit carries what it stood in for")
        XCTAssertEqual(
            suppressor.admit("a", now: start.addingTimeInterval(60)),
            .emit(suppressedRepeats: 0, suppressedWeight: 0),
            "the count resets with each emit")
    }

    /// A clock that moved BACKWARDS emits rather than going quiet. Failing closed on a bogus
    /// stamp would hide exactly the window someone is trying to read.
    func testAClockMovingBackwardsEmitsRatherThanSuppressing() {
        let suppressor = RepeatedEventSuppressor(minimumInterval: 30)
        XCTAssertEqual(suppressor.admit("a", now: start), .emit(suppressedRepeats: 0, suppressedWeight: 0))

        XCTAssertEqual(
            suppressor.admit("a", now: start.addingTimeInterval(-5)),
            .emit(suppressedRepeats: 0, suppressedWeight: 0))
    }

    /// A suppressed occurrence can stand for MANY client queries, so the weight must accumulate
    /// too. Folding a 20-client batch away as "1 repeat" would let an outage total read
    /// arbitrarily low — the same undercount the per-event client count had to fix upstream.
    func testSuppressedWeightAccumulatesSeparatelyFromTheRepeatCount() {
        let suppressor = RepeatedEventSuppressor(minimumInterval: 30)
        XCTAssertEqual(
            suppressor.admit("a", weight: 3, now: start),
            .emit(suppressedRepeats: 0, suppressedWeight: 0))

        XCTAssertEqual(suppressor.admit("a", weight: 20, now: start.addingTimeInterval(1)), .suppress)
        XCTAssertEqual(suppressor.admit("a", weight: 5, now: start.addingTimeInterval(2)), .suppress)

        XCTAssertEqual(
            suppressor.admit("a", weight: 1, now: start.addingTimeInterval(30)),
            .emit(suppressedRepeats: 2, suppressedWeight: 25),
            "two occurrences suppressed, standing for 25 client queries")
    }

    /// A burst that stops inside the interval and never recurs would otherwise strand its count
    /// forever — the tail is only reported when the SAME key is admitted again. Flushing is what
    /// makes the "nothing is silently lost" promise true.
    func testFlushHandsBackStrandedCountsWithoutResettingTheClock() {
        let suppressor = RepeatedEventSuppressor(minimumInterval: 30)
        XCTAssertEqual(
            suppressor.admit("b", weight: 1, now: start),
            .emit(suppressedRepeats: 0, suppressedWeight: 0))
        XCTAssertEqual(suppressor.admit("b", weight: 4, now: start.addingTimeInterval(1)), .suppress)
        XCTAssertEqual(suppressor.admit("a", weight: 1, now: start.addingTimeInterval(1)),
                       .emit(suppressedRepeats: 0, suppressedWeight: 0))
        XCTAssertEqual(suppressor.admit("a", weight: 2, now: start.addingTimeInterval(2)), .suppress)

        let flushed = suppressor.flushSuppressed()
        XCTAssertEqual(flushed.map(\.key), ["a", "b"], "sorted, so emitted output is stable")
        XCTAssertEqual(flushed.map(\.suppressedRepeats), [1, 1])
        XCTAssertEqual(flushed.map(\.suppressedWeight), [2, 4])

        XCTAssertTrue(
            suppressor.flushSuppressed().isEmpty,
            "flushing clears what it handed back — a tail is reported once, not every tick")

        // The clock is NOT reset: a still-running burst stays suppressed at the same cadence
        // rather than being granted a fresh interval by the flush.
        XCTAssertEqual(suppressor.admit("a", weight: 1, now: start.addingTimeInterval(3)), .suppress)
        XCTAssertEqual(
            suppressor.admit("a", weight: 1, now: start.addingTimeInterval(31)),
            .emit(suppressedRepeats: 1, suppressedWeight: 1),
            "and the post-flush suppressions are counted from zero")
    }

    func testAZeroIntervalNeverSuppresses() {
        let suppressor = RepeatedEventSuppressor(minimumInterval: 0)

        for _ in 0..<4 {
            XCTAssertEqual(suppressor.admit("a", now: start), .emit(suppressedRepeats: 0, suppressedWeight: 0))
        }
    }

    /// The ceiling exists so a caller that keys on something unbounded degrades into forgetting
    /// rather than growing without limit inside the ~50 MB NE process (`INV-MEM-1`). Eviction
    /// takes the least recently EMITTED key, so the busiest keys survive.
    func testTheKeyCeilingEvictsTheLeastRecentlyEmittedKey() {
        let suppressor = RepeatedEventSuppressor(minimumInterval: 30, maximumTrackedKeys: 2)

        XCTAssertEqual(suppressor.admit("old", now: start), .emit(suppressedRepeats: 0, suppressedWeight: 0))
        XCTAssertEqual(
            suppressor.admit("recent", now: start.addingTimeInterval(1)),
            .emit(suppressedRepeats: 0, suppressedWeight: 0))

        // A third key evicts "old" — the least recently emitted.
        XCTAssertEqual(
            suppressor.admit("new", now: start.addingTimeInterval(2)),
            .emit(suppressedRepeats: 0, suppressedWeight: 0))

        // "recent" is still tracked, so it stays suppressed inside its interval...
        XCTAssertEqual(suppressor.admit("recent", now: start.addingTimeInterval(3)), .suppress)
        // ...while "old" was forgotten and reads as a first occurrence again.
        XCTAssertEqual(
            suppressor.admit("old", now: start.addingTimeInterval(4)),
            .emit(suppressedRepeats: 0, suppressedWeight: 0))
    }
}
