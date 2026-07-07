import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ProtectionPauseStoreTests: XCTestCase {
    func testPauseRejectsNoActiveSessionWithoutIncrementingRevision() throws {
        let fixture = ProtectionPauseStoreFixture()

        let result = try fixture.store.pause(for: 300, requestedSessionID: "session-a")

        XCTAssertEqual(result.revision, 0)
        XCTAssertEqual(result.status, .rejected(.noActiveSession))
        XCTAssertNil(try fixture.store.currentPauseState())
        XCTAssertEqual(fixture.storage.integer(forKey: ProtectionPauseStore.Keys.commandRevision), 0)
    }

    func testPauseRejectsStaleSessionWithoutChangingStoredPause() throws {
        let fixture = ProtectionPauseStoreFixture()
        fixture.storage.set("current-session", forKey: ProtectionSessionStore.Keys.activeSessionID)

        let result = try fixture.store.pause(for: 300, requestedSessionID: "old-session")

        XCTAssertEqual(result.revision, 0)
        XCTAssertEqual(result.status, .rejected(.staleSession(activeSessionID: "current-session")))
        XCTAssertNil(try fixture.store.currentPauseState())
    }

    func testPauseStoresSessionBoundExpiryAndIncrementsRevision() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 1_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)

        let result = try fixture.store.pause(for: 600, requestedSessionID: "session-a")

        let expectedPause = ProtectionPauseState(
            sessionID: "session-a",
            pausedUntil: Date(timeIntervalSince1970: 1_600),
            revision: 1
        )
        XCTAssertEqual(result.revision, 1)
        XCTAssertEqual(result.status, .changed(expectedPause))
        XCTAssertEqual(try fixture.store.currentPauseState(), expectedPause)
    }

    func testDuplicatePauseCommandDoesNotExtendPauseOrIncrementRevision() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 1_200))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)

        let first = try fixture.store.pause(for: 600, requestedSessionID: "session-a", commandID: "pause-command-1")
        fixture.clock.advance(seconds: 60)
        let duplicate = try fixture.store.pause(for: 600, requestedSessionID: "session-a", commandID: "pause-command-1")

        let expectedPause = ProtectionPauseState(
            sessionID: "session-a",
            pausedUntil: Date(timeIntervalSince1970: 1_800),
            revision: 1
        )
        XCTAssertEqual(first.status, .changed(expectedPause))
        XCTAssertEqual(duplicate.revision, 1)
        XCTAssertEqual(duplicate.status, .unchanged(.duplicateCommand))
        XCTAssertEqual(try fixture.store.currentPauseState(), expectedPause)
    }

    func testPauseExpiryIsEvaluatedUsingInjectedClock() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 2_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)

        try fixture.store.pause(for: 60, requestedSessionID: "session-a")
        fixture.clock.advance(seconds: 59)
        XCTAssertNotNil(try fixture.store.currentPauseState())

        fixture.clock.advance(seconds: 2)
        XCTAssertNil(try fixture.store.currentPauseState())
    }

    func testResumeClearsActivePauseAndSecondResumeIsIdempotent() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 3_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: 300, requestedSessionID: "session-a")

        let firstResume = try fixture.store.resume(requestedSessionID: "session-a")
        let secondResume = try fixture.store.resume(requestedSessionID: "session-a")

        XCTAssertEqual(firstResume.revision, 2)
        XCTAssertEqual(firstResume.status, .changed(nil))
        XCTAssertNil(try fixture.store.currentPauseState())
        XCTAssertEqual(secondResume.revision, 2)
        XCTAssertEqual(secondResume.status, .unchanged(.noActivePause))
    }

    func testResumeWithoutActiveSessionAndNoStoredPauseIsIdempotent() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 3_500))

        let result = try fixture.store.resume(requestedSessionID: "session-a")

        XCTAssertEqual(result.revision, 0)
        XCTAssertEqual(result.status, .unchanged(.noActivePause))
    }

    func testResumeWithoutActiveSessionClearsStoredPauseAndIncrementsRevision() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 3_750))
        fixture.storage.set("old-session", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        fixture.storage.set(Date(timeIntervalSince1970: 4_000), forKey: ProtectionPauseStore.Keys.pausedUntil)

        let result = try fixture.store.resume(requestedSessionID: "session-a")

        XCTAssertEqual(result.revision, 1)
        XCTAssertEqual(result.status, .changed(nil))
        XCTAssertNil(fixture.storage.date(forKey: ProtectionPauseStore.Keys.pausedUntil))
        XCTAssertNil(fixture.storage.string(forKey: ProtectionPauseStore.Keys.pausedSessionID))
    }

    func testResumeClearsExpiredStoredPauseAndIncrementsRevision() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 4_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: 10, requestedSessionID: "session-a")
        fixture.clock.advance(seconds: 11)

        let result = try fixture.store.resume(requestedSessionID: "session-a")

        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(result.status, .changed(nil))
        XCTAssertNil(fixture.storage.date(forKey: ProtectionPauseStore.Keys.pausedUntil))
        XCTAssertNil(fixture.storage.string(forKey: ProtectionPauseStore.Keys.pausedSessionID))
        XCTAssertNil(try fixture.store.currentPauseState())
    }

    func testResumeClearsStoredPauseForStalePauseSessionWhenRequestMatchesActiveSession() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 5_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        fixture.storage.set("old-session", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        fixture.storage.set(Date(timeIntervalSince1970: 5_600), forKey: ProtectionPauseStore.Keys.pausedUntil)

        let result = try fixture.store.resume(requestedSessionID: "session-a")

        XCTAssertEqual(result.revision, 1)
        XCTAssertEqual(result.status, .changed(nil))
        XCTAssertNil(fixture.storage.date(forKey: ProtectionPauseStore.Keys.pausedUntil))
        XCTAssertNil(fixture.storage.string(forKey: ProtectionPauseStore.Keys.pausedSessionID))
        XCTAssertNil(try fixture.store.currentPauseState())
    }

    func testStoredPauseStateIncludesExpiredPauseWhileCurrentPauseStateHidesIt() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 1_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: 300, requestedSessionID: "session-a")

        fixture.clock.advance(seconds: 301)

        XCTAssertNil(try fixture.store.currentPauseState())
        let stored = try XCTUnwrap(try fixture.store.storedPauseState())
        XCTAssertEqual(stored.sessionID, "session-a")
        XCTAssertEqual(stored.pausedUntil, Date(timeIntervalSince1970: 1_300))
    }

    func testStoredPauseStateStaysSessionBound() throws {
        let fixture = ProtectionPauseStoreFixture()
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: 300, requestedSessionID: "session-a")

        fixture.storage.set("session-b", forKey: ProtectionSessionStore.Keys.activeSessionID)

        XCTAssertNil(try fixture.store.storedPauseState())
    }

    func testFarFuturePausedUntilReadsAsNotPausedInBothAccessors() throws {
        // A pausedUntil days ahead of now cannot be a pause the user could set
        // (a corrupt write, or a backward clock step that stretched a short pause
        // into the far future). Both read paths must treat it as not-paused so
        // filtering stays ON — the fail-closed direction.
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 10_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        fixture.storage.set("session-a", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        fixture.storage.set(
            Date(timeIntervalSince1970: 10_000 + 86_400),
            forKey: ProtectionPauseStore.Keys.pausedUntil
        )

        XCTAssertNil(try fixture.store.currentPauseState())
        XCTAssertNil(try fixture.store.storedPauseState())
    }

    func testStoredPauseStateApplyingSanityCapReportsAndDiscardsAnOverCapPause() throws {
        // The tunnel reconciles protection-ON off this flag even when its cache held no prior
        // pause (an intent-written pause it never learned), so the clamp must be REPORTED, not
        // silently swallowed — and the keys must be discarded so it is one-shot (Codex #208).
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 10_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        fixture.storage.set("session-a", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        fixture.storage.set(
            Date(timeIntervalSince1970: 10_000 + 86_400),
            forKey: ProtectionPauseStore.Keys.pausedUntil
        )

        let read = try fixture.store.storedPauseStateApplyingSanityCap()
        XCTAssertNil(read.state, "an over-cap pause reads as not-paused")
        XCTAssertTrue(read.clampedCappedPause, "the clamp must be reported so the caller can reconcile ON")
        XCTAssertNil(
            fixture.storage.date(forKey: ProtectionPauseStore.Keys.pausedUntil),
            "the over-cap keys must be discarded so the value cannot reactivate"
        )

        // A follow-up read finds no keys: nothing to clamp, nothing to report.
        let followUp = try fixture.store.storedPauseStateApplyingSanityCap()
        XCTAssertNil(followUp.state)
        XCTAssertFalse(followUp.clampedCappedPause)
    }

    func testStoredPauseStateApplyingSanityCapDoesNotFlagAnInWindowPause() throws {
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 20_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: 300, requestedSessionID: "session-a")
        fixture.clock.advance(seconds: 120)

        let read = try fixture.store.storedPauseStateApplyingSanityCap()
        XCTAssertNotNil(read.state)
        XCTAssertFalse(read.clampedCappedPause)
    }

    func testBackwardClockStepDroppingPauseBeyondCapReadsAsNotPaused() throws {
        // Pause the max length, then step the wall clock back an hour: pausedUntil
        // now sits further ahead than any selectable pause, so both accessors must
        // surface protection-ON rather than honour ~80 minutes of stale off-window.
        let maxSeconds = LiveActivityPausePreference.duration(
            forMinutes: LiveActivityPausePreference.maximumMinutes
        )
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 100_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: maxSeconds, requestedSessionID: "session-a")
        XCTAssertNotNil(try fixture.store.currentPauseState())

        fixture.clock.now = Date(timeIntervalSince1970: 100_000 - 3_600)

        XCTAssertNil(try fixture.store.currentPauseState())
        XCTAssertNil(try fixture.store.storedPauseState())
    }

    func testInWindowPauseStillReadsAsPaused() throws {
        // A normal, in-window pause must be unaffected by the sanity cap.
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 20_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: 300, requestedSessionID: "session-a")

        fixture.clock.advance(seconds: 120)

        XCTAssertNotNil(try fixture.store.currentPauseState())
        XCTAssertNotNil(try fixture.store.storedPauseState())
    }

    func testPauseAtSanityCapBoundaryBehavesSanely() throws {
        // Exactly maxDuration + slack ahead must still read as paused (the slack
        // exists to avoid clipping a legitimately-just-set maximum pause); one
        // second past the ceiling must read as not-paused.
        let ceiling = LiveActivityPausePreference.duration(
            forMinutes: LiveActivityPausePreference.maximumMinutes
        ) + ProtectionPauseStore.pauseSanityCapSlack

        let atBoundary = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 30_000))
        atBoundary.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        atBoundary.storage.set("session-a", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        atBoundary.storage.set(
            Date(timeIntervalSince1970: 30_000).addingTimeInterval(ceiling),
            forKey: ProtectionPauseStore.Keys.pausedUntil
        )
        XCTAssertNotNil(try atBoundary.store.currentPauseState())
        XCTAssertNotNil(try atBoundary.store.storedPauseState())

        let pastBoundary = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 30_000))
        pastBoundary.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        pastBoundary.storage.set("session-a", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        pastBoundary.storage.set(
            Date(timeIntervalSince1970: 30_000).addingTimeInterval(ceiling + 1),
            forKey: ProtectionPauseStore.Keys.pausedUntil
        )
        XCTAssertNil(try pastBoundary.store.currentPauseState())
        XCTAssertNil(try pastBoundary.store.storedPauseState())
    }

    func testCappedPauseIsClearedSoItCannotReactivateWhenClockMovesIntoRange() throws {
        // Codex #208: hiding a capped pausedUntil is not enough — if the keys survive, the
        // value re-enables the pause once clock.now moves (or is corrected) to within the
        // ceiling of that date. Reading a capped pause must DISCARD it, so protection stays
        // ON even after the clock catches up.
        let maxSeconds = LiveActivityPausePreference.duration(
            forMinutes: LiveActivityPausePreference.maximumMinutes
        )
        let fixture = ProtectionPauseStoreFixture(now: Date(timeIntervalSince1970: 1_000_000))
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        fixture.storage.set("session-a", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        // A corrupt days-ahead pausedUntil.
        let corruptUntil = Date(timeIntervalSince1970: 1_000_000 + 3 * 86_400)
        fixture.storage.set(corruptUntil, forKey: ProtectionPauseStore.Keys.pausedUntil)

        // The first read caps the pause AND clears the keys.
        XCTAssertNil(try fixture.store.currentPauseState())
        XCTAssertNil(fixture.storage.date(forKey: ProtectionPauseStore.Keys.pausedUntil))
        XCTAssertNil(fixture.storage.string(forKey: ProtectionPauseStore.Keys.pausedSessionID))

        // Move the clock to within a normal window of the (now-cleared) corrupt date. Without
        // clearing this would re-enable the pause; with it, both accessors stay not-paused.
        fixture.clock.now = corruptUntil.addingTimeInterval(-maxSeconds / 2)
        XCTAssertNil(try fixture.store.currentPauseState())
        XCTAssertNil(try fixture.store.storedPauseState())
    }

    func testCappedDiscardPreservesAFreshPauseWrittenByAnotherProcess() throws {
        // Codex #208: the read path holds only the in-process lock, so another process can write
        // a fresh valid pause between the accessor's pausedUntil read and the capped-key clear.
        // Compare-and-clear must leave that newer pause intact (only clear the exact capped pair).
        let now = Date(timeIntervalSince1970: 1_000_000)
        let storage = MutatingProtectionKeyValueStore()
        let store = ProtectionPauseStore(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            clock: FakeProtectionClock(now: now)
        )
        storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        storage.set("session-a", forKey: ProtectionPauseStore.Keys.pausedSessionID)
        storage.set(now.addingTimeInterval(3 * 86_400), forKey: ProtectionPauseStore.Keys.pausedUntil)

        // Right after the accessor's FIRST pausedUntil read (the capped stale value) and before
        // the compare re-read, another process writes a fresh in-window pause.
        let freshUntil = now.addingTimeInterval(300)
        storage.onDatePausedUntilRead = { [weak storage] readCount in
            if readCount == 1 {
                storage?.setDirect(freshUntil, forKey: ProtectionPauseStore.Keys.pausedUntil)
            }
        }

        // The accessor caps the stale value it read (returns nil) but must NOT delete the fresh
        // pause the compare now sees.
        XCTAssertNil(try store.storedPauseState())
        storage.onDatePausedUntilRead = nil
        XCTAssertEqual(
            storage.date(forKey: ProtectionPauseStore.Keys.pausedUntil),
            freshUntil,
            "a fresh pause written mid-clear must be preserved, not clobbered by the read-side cap"
        )
        // And it reads back as a valid, in-window pause.
        XCTAssertEqual(try store.storedPauseState()?.pausedUntil, freshUntil)
    }

    func testClearStoredPauseRemovesKeysWithoutMintingRevision() throws {
        let fixture = ProtectionPauseStoreFixture()
        fixture.storage.set("session-a", forKey: ProtectionSessionStore.Keys.activeSessionID)
        try fixture.store.pause(for: 300, requestedSessionID: "session-a")
        XCTAssertEqual(try fixture.store.currentRevision(), 1)

        try fixture.store.clearStoredPause()

        XCTAssertNil(fixture.storage.date(forKey: ProtectionPauseStore.Keys.pausedUntil))
        XCTAssertNil(fixture.storage.string(forKey: ProtectionPauseStore.Keys.pausedSessionID))
        XCTAssertEqual(
            try fixture.store.currentRevision(),
            1,
            "Expiry cleanup is an observation, not a command; it must not invalidate newer Live Activity updates."
        )
    }
}

/// A storage that fires a hook after each `pausedUntil` date read, letting a test simulate a
/// cross-process write landing between the read-side cap's read and its compare-and-clear.
private final class MutatingProtectionKeyValueStore: ProtectionKeyValueStorage, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private var pausedUntilReadCount = 0
    var onDatePausedUntilRead: ((Int) -> Void)?

    func string(forKey key: String) -> String? { values[key] as? String }

    func date(forKey key: String) -> Date? {
        let value = values[key] as? Date
        if key == ProtectionPauseStore.Keys.pausedUntil {
            pausedUntilReadCount += 1
            onDatePausedUntilRead?(pausedUntilReadCount)
        }
        return value
    }

    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func set(_ value: Date, forKey key: String) { values[key] = value }
    func set(_ value: Int, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }

    /// Write that does NOT trip the read hook — the test uses it inside the hook itself.
    func setDirect(_ value: Date, forKey key: String) { values[key] = value }
}

private final class ProtectionPauseStoreFixture {
    let storage: FakeProtectionKeyValueStore
    let clock: FakeProtectionClock
    let store: ProtectionPauseStore

    init(now: Date = Date(timeIntervalSince1970: 1_000)) {
        storage = FakeProtectionKeyValueStore()
        clock = FakeProtectionClock(now: now)
        store = ProtectionPauseStore(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            clock: clock
        )
    }
}
