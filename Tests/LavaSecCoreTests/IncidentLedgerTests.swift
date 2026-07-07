import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class IncidentLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Reason sanitization (worker-contract mirror)

    func testReasonAcceptsOnlyKebabCasePolicyLabels() {
        // The worker rejects a ledger ROW whose reason is not kebab-case (defense in
        // depth against domain-shaped content); the writer enforces the same shape so
        // an off-shape reason costs only the reason field, never the record.
        for valid in ["upstream-failed", "dns-wedged", "rejected-response", "timeout", "a", "x2-y"] {
            XCTAssertEqual(IncidentLedgerRecord.sanitizedReason(valid), valid, valid)
        }
        for invalid in [
            "resolver-error: secret-site.example refused",  // colon + dot + space
            "secret-site.example",                          // domain-shaped
            "2026-06-22T00:00:00Z",                         // timestamp-shaped
            "Upstream-Failed",                              // uppercase
            "-leading-hyphen",
            "",
            String(repeating: "a", count: 101)
        ] {
            XCTAssertNil(IncidentLedgerRecord.sanitizedReason(invalid), invalid)
        }
    }

    func testRecordDropsOffShapeReasonButKeepsTheRecord() {
        let record = IncidentLedgerRecord(
            at: now,
            kind: .wedgeDetected,
            reason: "resolver-error: secret-site.example refused"
        )

        XCTAssertNil(record.reason, "an off-shape reason is dropped at the writer")
        XCTAssertEqual(record.kind, .wedgeDetected, "the record itself survives")
    }

    // MARK: - Ring semantics

    func testAppendBoundsToFiftyRecordsOldestFirst() {
        var ledger = IncidentLedger()
        for index in 0..<55 {
            ledger.append(IncidentLedgerRecord(
                at: now.addingTimeInterval(TimeInterval(index)),
                kind: .selfReconnectCommitted
            ))
        }

        XCTAssertEqual(ledger.records.count, IncidentLedger.maximumRecordCount)
        XCTAssertEqual(
            ledger.records.first?.at,
            now.addingTimeInterval(5),
            "the OLDEST records are evicted first — the ring keeps the newest 50"
        )
    }

    func testRecentRecordsFiltersToTheSevenDayWindowWithoutMutating() {
        let ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-10 * 86_400), kind: .wedgeDetected),
            IncidentLedgerRecord(at: now.addingTimeInterval(-1 * 86_400), kind: .wedgeRecovered)
        ])

        XCTAssertEqual(ledger.recentRecords(now: now).map(\.kind), [.wedgeRecovered])
        XCTAssertEqual(ledger.records.count, 2, "retention is a read-time VIEW — the stored timeline is untouched")
    }

    // MARK: - Clock-skew safety (COH-4)

    func testFutureDatedAppendNeverWipesTheExistingTimeline() {
        // Device clock jumps >7d ahead while an incident is written. The original append
        // pruned relative to the incoming record's own `at`, wiping the whole timeline.
        var ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-2 * 86_400), kind: .selfReconnectCommitted),
            IncidentLedgerRecord(at: now.addingTimeInterval(-1 * 86_400), kind: .selfReconnectCredited)
        ])

        ledger.append(IncidentLedgerRecord(at: now.addingTimeInterval(30 * 86_400), kind: .wedgeDetected))

        XCTAssertEqual(ledger.records.count, 3, "append must not time-prune — a bad write clock cannot wipe history")
        XCTAssertEqual(ledger.records.map(\.kind), [.selfReconnectCommitted, .selfReconnectCredited, .wedgeDetected])
    }

    func testCombinedSkewReadReturnsNothingButDestroysNothing() {
        // The Codex round-1 scenario: the clock jumps 30d forward, the tunnel appends an
        // incident stamped with the skewed clock, and the app reads a report moments later
        // with the SAME skewed clock. Any persisted clock-derived prune (including
        // min(now, newest) — the future record IS the newest) would wipe the pre-skew
        // timeline here. The filter view returns only the skew-stamped record and leaves
        // the file intact, so the next honest-clock read recovers the real timeline.
        var ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-2 * 86_400), kind: .wedgeDetected),
            IncidentLedgerRecord(at: now, kind: .wedgeRecovered)
        ])
        let skewedNow = now.addingTimeInterval(30 * 86_400)
        ledger.append(IncidentLedgerRecord(at: skewedNow, kind: .selfReconnectCommitted))

        XCTAssertEqual(ledger.recentRecords(now: skewedNow).map(\.kind), [.selfReconnectCommitted])
        XCTAssertEqual(ledger.records.count, 3, "a skewed read must never destroy the stored timeline")

        // Clock recovers: the report self-heals to the real records; the future-stamped
        // record is excluded (an incident "that hasn't happened yet") until the size cap
        // or the user's clear removes it.
        XCTAssertEqual(ledger.recentRecords(now: now).map(\.kind), [.wedgeDetected, .wedgeRecovered])
    }

    func testForwardSkewedReadClockReturnsEmptyAndSelfHeals() {
        let ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-2 * 86_400), kind: .wedgeDetected),
            IncidentLedgerRecord(at: now, kind: .wedgeRecovered)
        ])

        // Reader clock 30 days ahead with no skew-stamped writes: the window is honestly
        // unknowable, so the report is empty — but nothing is deleted, and the next read
        // with a recovered clock sees the full timeline again.
        XCTAssertTrue(ledger.recentRecords(now: now.addingTimeInterval(30 * 86_400)).isEmpty)
        XCTAssertEqual(ledger.recentRecords(now: now).count, 2)
    }

    // MARK: - Two-phase retention sweep

    func testSweepArmsFirstThenDeletesAfterCorroboration() {
        var ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-10 * 86_400), kind: .wedgeDetected),
            IncidentLedgerRecord(at: now.addingTimeInterval(-1 * 86_400), kind: .wedgeRecovered)
        ])

        XCTAssertTrue(ledger.sweepExpired(now: now), "first observation arms")
        XCTAssertEqual(ledger.expirySweepArmedAt, now)
        XCTAssertEqual(ledger.records.count, 2, "arming never deletes")

        XCTAssertFalse(
            ledger.sweepExpired(now: now.addingTimeInterval(3_600)),
            "inside the corroboration day: no change"
        )
        XCTAssertEqual(ledger.records.count, 2)

        XCTAssertTrue(ledger.sweepExpired(now: now.addingTimeInterval(25 * 3_600)))
        XCTAssertEqual(
            ledger.records.map(\.kind),
            [.wedgeRecovered],
            "a clock asserting staleness for a sustained day enforces the on-disk window"
        )
        XCTAssertNil(ledger.expirySweepArmedAt)
    }

    func testTransientForwardSkewArmsThenDisarmsWithoutLoss() {
        var ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-1 * 86_400), kind: .wedgeDetected)
        ])

        // Clock glitches 30d forward: the fresh record looks stale — the sweep only arms.
        XCTAssertTrue(ledger.sweepExpired(now: now.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(ledger.records.count, 1)

        // Clock recovers: nothing is stale, so the pending observation is discarded.
        XCTAssertTrue(ledger.sweepExpired(now: now))
        XCTAssertNil(ledger.expirySweepArmedAt)
        XCTAssertEqual(ledger.records.count, 1, "a transient skew can never cost a record")
    }

    func testBackwardClockReArmsFromTheEarlierReading() {
        var ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-10 * 86_400), kind: .wedgeDetected)
        ])

        // Armed by a clock 30d ahead. The honest clock still sees the record as stale,
        // but must not confirm against a mark left by a clock AHEAD of it — re-arm.
        XCTAssertTrue(ledger.sweepExpired(now: now.addingTimeInterval(30 * 86_400)))
        XCTAssertTrue(ledger.sweepExpired(now: now))
        XCTAssertEqual(ledger.expirySweepArmedAt, now)
        XCTAssertEqual(ledger.records.count, 1)

        XCTAssertTrue(ledger.sweepExpired(now: now.addingTimeInterval(25 * 3_600)))
        XCTAssertTrue(ledger.records.isEmpty)
    }

    func testSkewedConfirmationDeletesOnlyRowsCorroboratedAtArmTime() {
        var ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-10 * 86_400), kind: .wedgeDetected),
            IncidentLedgerRecord(at: now.addingTimeInterval(-1 * 86_400), kind: .wedgeRecovered)
        ])

        // Honest arm on the genuinely stale row, then the corroboration window passes
        // and a single forward-skewed reading confirms. Deletion is keyed to the
        // ARM-time cutoff, so the skewed reading can only delete what the armed
        // observation already saw as stale — never rows that are only "stale" by its
        // own lying clock (Codex round 5).
        XCTAssertTrue(ledger.sweepExpired(now: now))
        XCTAssertTrue(ledger.sweepExpired(now: now.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(ledger.records.map(\.kind), [.wedgeRecovered])
    }

    func testPartialConfirmReArmsOnRowsThatAgedDuringCorroboration() {
        var ledger = IncidentLedger(records: [
            IncidentLedgerRecord(at: now.addingTimeInterval(-10 * 86_400), kind: .wedgeDetected),
            IncidentLedgerRecord(at: now.addingTimeInterval(-6 * 86_400), kind: .wedgeRecovered)
        ])

        XCTAssertTrue(ledger.sweepExpired(now: now), "arms on the 10-day-old row")
        let confirmAt = now.addingTimeInterval(25 * 3_600)
        XCTAssertTrue(ledger.sweepExpired(now: confirmAt))
        XCTAssertEqual(
            ledger.records.map(\.kind),
            [.wedgeRecovered],
            "only the arm-corroborated row is deleted"
        )
        XCTAssertEqual(
            ledger.expirySweepArmedAt,
            confirmAt,
            "a row that aged during corroboration re-arms immediately instead of waiting for a future sweep (Codex round 6)"
        )

        XCTAssertTrue(ledger.sweepExpired(now: confirmAt.addingTimeInterval(25 * 3_600)))
        XCTAssertTrue(ledger.records.isEmpty, "it ages out after its OWN corroboration day")
        XCTAssertNil(ledger.expirySweepArmedAt)
    }

    func testConfirmWithoutArmCorroboratedRowsReArmsInsteadOfDeleting() {
        var ledger = IncidentLedger(
            records: [IncidentLedgerRecord(at: now.addingTimeInterval(-6 * 86_400), kind: .wedgeDetected)],
            expirySweepArmedAt: now
        )

        // The only stale-by-now row postdates the armed observation (it crossed the
        // window DURING corroboration, or the armed row fell to the size cap): nothing
        // is two-reading corroborated, so the sweep re-arms rather than deletes.
        XCTAssertTrue(ledger.sweepExpired(now: now.addingTimeInterval(2 * 86_400)))
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.expirySweepArmedAt, now.addingTimeInterval(2 * 86_400))
    }

    func testPersistenceAppendUnderCombinedSkewOnlyArms() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-ledger-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("incident-ledger.json")

        IncidentLedgerPersistence.append(
            IncidentLedgerRecord(at: now.addingTimeInterval(-2 * 86_400), kind: .wedgeDetected),
            to: url
        )
        // Combined skew: one call appends the 30d-forward-stamped record AND sweeps with
        // that same skewed stamp — the real timeline suddenly looks stale.
        IncidentLedgerPersistence.append(
            IncidentLedgerRecord(at: now.addingTimeInterval(30 * 86_400), kind: .selfReconnectCommitted),
            to: url
        )
        XCTAssertEqual(
            IncidentLedgerPersistence.load(from: url).records.count, 2,
            "a skewed write arms the sweep but deletes nothing"
        )

        // Startup sweep with the recovered clock: nothing is stale, so the pending
        // observation is discarded and the timeline is intact.
        IncidentLedgerPersistence.sweepExpired(at: url, now: now)
        let ledger = IncidentLedgerPersistence.load(from: url)
        XCTAssertNil(ledger.expirySweepArmedAt)
        XCTAssertEqual(ledger.records.count, 2)
    }

    // MARK: - Persistence

    func testPersistenceRoundTripAppendAndWindowedRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-ledger-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("incident-ledger.json")

        IncidentLedgerPersistence.append(
            IncidentLedgerRecord(at: now.addingTimeInterval(-8 * 86_400), kind: .failClosedEntered, reason: "snapshot-unavailable"),
            to: url
        )
        IncidentLedgerPersistence.append(
            IncidentLedgerRecord(at: now, kind: .wedgeRecovered, reason: "rejected-response", durationMs: 31_500, verifiedBy: "smoke-probe"),
            to: url
        )

        let recent = IncidentLedgerPersistence.load(from: url).recentRecords(now: now)
        XCTAssertEqual(recent.count, 1, "the 8-day-old record falls outside the report window")
        let record = try XCTUnwrap(recent.first)
        XCTAssertEqual(record.kind, .wedgeRecovered)
        XCTAssertEqual(record.reason, "rejected-response")
        XCTAssertEqual(record.durationMs, 31_500)
        XCTAssertEqual(record.verifiedBy, "smoke-probe")

        // The read is a pure view: the stored file keeps both records (deleted only by
        // the size cap, the user's clear, or the corroborated retention sweep — never
        // by a report-time read; the append-side sweep here has only ARMED).
        XCTAssertEqual(IncidentLedgerPersistence.load(from: url).records.count, 2)

        IncidentLedgerPersistence.clear(at: url)
        XCTAssertTrue(IncidentLedgerPersistence.load(from: url).records.isEmpty)
    }

    func testLoadFromMissingOrCorruptFileIsEmptyNeverThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-ledger-missing-\(UUID().uuidString).json")
        XCTAssertTrue(IncidentLedgerPersistence.load(from: missing).records.isEmpty)

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-ledger-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try? Data("not json".utf8).write(to: corrupt)
        XCTAssertTrue(IncidentLedgerPersistence.load(from: corrupt).records.isEmpty)
    }

    // MARK: - CON-1 non-blocking writer (drop on contention, never stall)

    func testAppendDropsInsteadOfBlockingWhenTheLockIsHeld() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-ledger-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("incident-ledger.json")
        let lockURL = url.appendingPathExtension("lock")

        // Hold the exclusive app-group lock the way a SUSPENDED app would, on a separate
        // open file description (flock excludes across descriptions, even same-process).
        let heldDescriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(heldDescriptor, 0)
        XCTAssertEqual(flock(heldDescriptor, LOCK_EX), 0)
        defer { flock(heldDescriptor, LOCK_UN); close(heldDescriptor) }

        let started = Date()
        let wrote = IncidentLedgerPersistence.append(
            IncidentLedgerRecord(at: now, kind: .wedgeDetected),
            to: url
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(wrote, "a contended writer drops the record, it does not block")
        XCTAssertLessThan(elapsed, 1.0, "the acquire is bounded — DNS serving can never wedge on a held lock")
        XCTAssertTrue(IncidentLedgerPersistence.load(from: url).records.isEmpty, "nothing partial is written")

        // A retention sweep is a writer too: also drops rather than blocks.
        XCTAssertFalse(IncidentLedgerPersistence.sweepExpired(at: url, now: now))
    }

    func testAppendWritesWhenTheLockIsFree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-ledger-free-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("incident-ledger.json")

        XCTAssertTrue(IncidentLedgerPersistence.append(IncidentLedgerRecord(at: now, kind: .wedgeDetected), to: url))
        XCTAssertEqual(IncidentLedgerPersistence.load(from: url).records.map(\.kind), [.wedgeDetected])
    }

    func testTryClearDropsInsteadOfBlockingWhenTheLockIsHeld() throws {
        // The tunnel-side ledger clear shares the queue the terminal self-reconnect commit
        // drains via `sync`, so it must be non-blocking: a blocking clear on a lock a
        // suspended app holds would stall the teardown and recreate the DNS outage (Codex
        // #200 P2). This mirrors the append drop-test.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-ledger-tryclear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("incident-ledger.json")
        let lockURL = url.appendingPathExtension("lock")

        // A record exists on disk before the clear is attempted.
        XCTAssertTrue(IncidentLedgerPersistence.append(IncidentLedgerRecord(at: now, kind: .wedgeDetected), to: url))

        // Hold the exclusive app-group lock the way a SUSPENDED app would.
        let heldDescriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(heldDescriptor, 0)
        XCTAssertEqual(flock(heldDescriptor, LOCK_EX), 0)

        let started = Date()
        let cleared = IncidentLedgerPersistence.tryClear(at: url)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(cleared, "a contended clear drops rather than blocking the terminal-sync queue")
        XCTAssertLessThan(elapsed, 1.0, "the acquire is bounded — the self-reconnect teardown can never wedge on a held lock")
        XCTAssertFalse(IncidentLedgerPersistence.load(from: url).records.isEmpty, "the drop leaves the file untouched")

        // Once the lock is free the same clear removes the file. (The app's blocking `clear`
        // is the reliable backstop off the teardown path; this bounded one is best-effort.)
        flock(heldDescriptor, LOCK_UN)
        close(heldDescriptor)
        XCTAssertTrue(IncidentLedgerPersistence.tryClear(at: url))
        XCTAssertTrue(IncidentLedgerPersistence.load(from: url).records.isEmpty)
    }
}
