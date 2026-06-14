import XCTest
@testable import LavaSecCore

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
