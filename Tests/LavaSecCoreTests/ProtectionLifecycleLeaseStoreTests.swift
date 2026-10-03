import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ProtectionLifecycleLeaseStoreTests: XCTestCase {
    func testFileStoragePersistsACompleteRecordVisibleToAFreshReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("lifecycle-state.json")

        let writerStorage = try ProtectionFileKeyValueStorage(fileURL: fileURL)
        let writer = ProtectionLifecycleLeaseStore(
            storage: writerStorage,
            lock: ProtectionNoopCriticalSectionLock(),
            clock: FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000)),
            makeToken: { "restart-token" }
        )
        let lease = try XCTUnwrap(writer.claimExplicitRestart(leaseDuration: 30))
        try writerStorage.persistIfNeeded()

        let readerStorage = try ProtectionFileKeyValueStorage(fileURL: fileURL)
        let reader = ProtectionLifecycleLeaseStore(
            storage: readerStorage,
            lock: ProtectionNoopCriticalSectionLock(),
            clock: FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        )

        XCTAssertEqual(try reader.currentLease(), lease)
        XCTAssertEqual(try reader.currentExternalRestartGeneration(), lease.token)
    }

    func testRestartClaimBlocksRestoreCapturedBeforeItAndRotatesGeneration() throws {
        let fixture = LeaseStoreFixture(tokens: ["restart-token"])
        let capturedGeneration = try fixture.store.currentExternalRestartGeneration()

        let restartLease = try XCTUnwrap(
            fixture.store.claimExplicitRestart(leaseDuration: 30)
        )

        XCTAssertEqual(try fixture.store.currentExternalRestartGeneration(), "restart-token")
        XCTAssertEqual(restartLease.owner, .explicitRestart)
        XCTAssertNil(
            try fixture.store.claimAutomaticRestore(
                expectedExternalRestartGeneration: capturedGeneration,
                leaseDuration: 30
            ),
            "A restart accepted after restore capture must invalidate and exclude that restore."
        )
    }

    func testAutomaticRestoreClaimBlocksRestartWithoutRotatingGeneration() throws {
        let fixture = LeaseStoreFixture(tokens: ["restore-token", "restart-token"])
        let capturedGeneration = try fixture.store.currentExternalRestartGeneration()
        let restoreLease = try XCTUnwrap(
            fixture.store.claimAutomaticRestore(
                expectedExternalRestartGeneration: capturedGeneration,
                leaseDuration: 30
            )
        )

        XCTAssertEqual(restoreLease.owner, .automaticRestore)
        XCTAssertNil(try fixture.store.claimExplicitRestart(leaseDuration: 30))
        XCTAssertEqual(
            try fixture.store.currentExternalRestartGeneration(),
            capturedGeneration,
            "A rejected restart must not invalidate requests as though it ran."
        )

        XCTAssertTrue(try fixture.store.release(restoreLease))
        XCTAssertNotNil(try fixture.store.claimExplicitRestart(leaseDuration: 30))
        XCTAssertEqual(try fixture.store.currentExternalRestartGeneration(), "restart-token")
    }

    func testExpiredLeaseCanBeRecoveredAndStaleReleaseCannotClearNewOwner() throws {
        let fixture = LeaseStoreFixture(tokens: ["stale-restore", "new-restart"])
        let staleRestore = try XCTUnwrap(
            fixture.store.claimAutomaticRestore(
                expectedExternalRestartGeneration: nil,
                leaseDuration: 10
            )
        )

        fixture.clock.advance(seconds: 11)
        let newRestart = try XCTUnwrap(fixture.store.claimExplicitRestart(leaseDuration: 10))

        XCTAssertFalse(try fixture.store.release(staleRestore))
        XCTAssertEqual(try fixture.store.currentLease(), newRestart)
    }

    func testRenewalKeepsOwnedLeaseLiveAndCannotReviveItAfterExpiry() throws {
        let fixture = LeaseStoreFixture(tokens: ["restore", "restart"])
        let restore = try XCTUnwrap(
            fixture.store.claimAutomaticRestore(
                expectedExternalRestartGeneration: nil,
                leaseDuration: 10
            )
        )

        fixture.clock.advance(seconds: 8)
        XCTAssertTrue(try fixture.store.renew(restore, leaseDuration: 10))
        XCTAssertTrue(
            try fixture.store.isOwned(restore),
            "Renewal changes expiry but must preserve ownership of the original token."
        )
        fixture.clock.advance(seconds: 3)
        XCTAssertNil(try fixture.store.claimExplicitRestart(leaseDuration: 10))

        fixture.clock.advance(seconds: 8)
        XCTAssertFalse(try fixture.store.isOwned(restore))
        XCTAssertFalse(try fixture.store.renew(restore, leaseDuration: 10))
        XCTAssertNotNil(try fixture.store.claimExplicitRestart(leaseDuration: 10))
    }
}

private final class LeaseStoreFixture {
    let clock = FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
    let store: ProtectionLifecycleLeaseStore

    init(tokens: [String]) {
        let tokenSequence = LeaseTokenSequence(tokens)
        store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock(),
            clock: clock,
            makeToken: { tokenSequence.next() }
        )
    }
}

private final class LeaseTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        precondition(!tokens.isEmpty)
        return tokens.removeFirst()
    }
}
