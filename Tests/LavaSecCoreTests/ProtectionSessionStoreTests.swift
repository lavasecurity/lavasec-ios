import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ProtectionSessionStoreTests: XCTestCase {
    func testStoresAndReadsActiveSessionInsideCriticalSection() throws {
        let storage = FakeProtectionKeyValueStore()
        let lock = RecordingProtectionCriticalSectionLock()
        let store = ProtectionSessionStore(storage: storage, lock: lock)

        let result = try store.setActiveSessionID("session-a")

        XCTAssertEqual(result, .changed(activeSessionID: "session-a"))
        XCTAssertEqual(try store.activeSessionID(), "session-a")
        XCTAssertEqual(lock.entryCount, 2)
    }

    func testEmptyStoredSessionIsTreatedAsNoActiveSession() throws {
        let storage = FakeProtectionKeyValueStore()
        let store = ProtectionSessionStore(storage: storage, lock: RecordingProtectionCriticalSectionLock())

        storage.set("", forKey: ProtectionSessionStore.Keys.activeSessionID)

        XCTAssertNil(try store.activeSessionID())
        XCTAssertFalse(try store.isActive(sessionID: "session-a"))
    }

    func testSettingEmptySessionDoesNotClearExistingActiveSession() throws {
        let storage = FakeProtectionKeyValueStore()
        let store = ProtectionSessionStore(storage: storage, lock: RecordingProtectionCriticalSectionLock())
        try store.setActiveSessionID("session-a")

        let result = try store.setActiveSessionID("")

        XCTAssertEqual(result, .unchanged(activeSessionID: "session-a"))
        XCTAssertEqual(try store.activeSessionID(), "session-a")
    }

    func testClearingWithStaleSessionIDIsRejectedAndLeavesActiveSessionUntouched() throws {
        let storage = FakeProtectionKeyValueStore()
        let store = ProtectionSessionStore(storage: storage, lock: RecordingProtectionCriticalSectionLock())

        try store.setActiveSessionID("current-session")

        let result = try store.clearActiveSessionID(matching: "old-session")

        XCTAssertEqual(result, .rejected(.staleSession(activeSessionID: "current-session")))
        XCTAssertEqual(try store.activeSessionID(), "current-session")
    }

    func testClearingMatchingActiveSessionRemovesSession() throws {
        let storage = FakeProtectionKeyValueStore()
        let store = ProtectionSessionStore(storage: storage, lock: RecordingProtectionCriticalSectionLock())

        try store.setActiveSessionID("session-a")

        let result = try store.clearActiveSessionID(matching: "session-a")

        XCTAssertEqual(result, .changed(activeSessionID: nil))
        XCTAssertNil(try store.activeSessionID())
    }

    func testUnconditionalClearRemovesAnySessionAndIsIdempotent() throws {
        let storage = FakeProtectionKeyValueStore()
        let store = ProtectionSessionStore(storage: storage, lock: RecordingProtectionCriticalSectionLock())

        try store.setActiveSessionID("session-a")
        XCTAssertEqual(try store.clearActiveSessionID(), .changed(activeSessionID: nil))
        XCTAssertNil(try store.activeSessionID())
        XCTAssertEqual(try store.clearActiveSessionID(), .unchanged(activeSessionID: nil))
    }

    func testBeginFreshSessionReplacesExistingSession() throws {
        let storage = FakeProtectionKeyValueStore()
        let store = ProtectionSessionStore(storage: storage, lock: RecordingProtectionCriticalSectionLock())

        try store.setActiveSessionID("session-a")
        let fresh = try store.beginFreshSession(id: "session-b")

        XCTAssertEqual(fresh, "session-b")
        XCTAssertEqual(try store.activeSessionID(), "session-b")
    }

    func testEnsureActiveSessionReturnsExistingOrMintsOne() throws {
        let storage = FakeProtectionKeyValueStore()
        let store = ProtectionSessionStore(storage: storage, lock: RecordingProtectionCriticalSectionLock())

        let minted = try store.ensureActiveSessionID()
        XCTAssertFalse(minted.isEmpty)
        XCTAssertEqual(try store.ensureActiveSessionID(), minted)

        try store.setActiveSessionID("session-a")
        XCTAssertEqual(try store.ensureActiveSessionID(), "session-a")
    }
}
