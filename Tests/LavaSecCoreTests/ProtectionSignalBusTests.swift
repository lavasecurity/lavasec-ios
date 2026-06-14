import XCTest
@testable import LavaSecCore

final class ProtectionSignalBusTests: XCTestCase {
    func testPublishWritesRevisionedStateAndPostsTypedWakeup() throws {
        let storage = FakeProtectionKeyValueStore()
        let notifier = RecordingProtectionSignalNotifier()
        let bus = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: notifier
        )

        let signal = try bus.publish(.pauseStateChanged)

        XCTAssertEqual(signal, ProtectionSignal(kind: .pauseStateChanged, revision: 1))
        XCTAssertEqual(storage.integer(forKey: ProtectionSignalKind.pauseStateChanged.revisionKey), 1)
        XCTAssertEqual(notifier.postedNames, [ProtectionSignalKind.pauseStateChanged.notificationName])
    }

    func testPublishPostsWakeupAfterReleasingLock() throws {
        let storage = FakeProtectionKeyValueStore()
        let lock = RecordingProtectionCriticalSectionLock()
        let notifier = ReentrantProtectionSignalNotifier()
        let bus = ProtectionSignalBus(
            storage: storage,
            lock: lock,
            notifier: notifier
        )
        var delivery: ProtectionSignalDelivery?
        var observedName: String?

        notifier.onPostNotification = { name in
            observedName = name
            XCTAssertFalse(lock.isInsideCriticalSection)
            XCTAssertEqual(storage.integer(forKey: ProtectionSignalKind.pauseStateChanged.revisionKey), 1)
            guard !lock.isInsideCriticalSection else {
                return
            }
            delivery = try? bus.receiveWakeup(.pauseStateChanged)
        }

        let signal = try bus.publish(.pauseStateChanged)

        XCTAssertEqual(signal, ProtectionSignal(kind: .pauseStateChanged, revision: 1))
        XCTAssertEqual(observedName, ProtectionSignalKind.pauseStateChanged.notificationName)
        XCTAssertEqual(notifier.postedNames, [ProtectionSignalKind.pauseStateChanged.notificationName])
        XCTAssertEqual(delivery, .delivered(signal))
    }

    func testWakeupReadsLatestRevisionFromStorageWhenNotificationsArriveOutOfOrder() throws {
        let storage = FakeProtectionKeyValueStore()
        let writer = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )
        let reader = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )

        let first = try writer.publish(.pauseStateChanged)
        let second = try writer.publish(.pauseStateChanged)

        let delivery = try reader.receiveWakeup(.pauseStateChanged, observedRevision: first.revision)

        XCTAssertEqual(delivery, .delivered(second))
    }

    func testDuplicateWakeupsAreCoalescedByRevision() throws {
        let storage = FakeProtectionKeyValueStore()
        let writer = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )
        let reader = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )

        let signal = try writer.publish(.configurationChanged)

        XCTAssertEqual(try reader.receiveWakeup(.configurationChanged), .delivered(signal))
        XCTAssertEqual(try reader.receiveWakeup(.configurationChanged), .duplicate(currentRevision: signal.revision))
    }

    func testOutOfOrderRevisionHintIsDetectedAfterNewerSignalWasDelivered() throws {
        let storage = FakeProtectionKeyValueStore()
        let writer = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )
        let reader = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )

        let first = try writer.publish(.snapshotChanged)
        let second = try writer.publish(.snapshotChanged)

        XCTAssertEqual(try reader.receiveWakeup(.snapshotChanged, observedRevision: second.revision), .delivered(second))
        XCTAssertEqual(
            try reader.receiveWakeup(.snapshotChanged, observedRevision: first.revision),
            .stale(observedRevision: first.revision, currentRevision: second.revision)
        )
    }

    func testOlderWakeupHintStillDeliversNewerStoredRevision() throws {
        let storage = FakeProtectionKeyValueStore()
        let writer = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )
        let reader = ProtectionSignalBus(
            storage: storage,
            lock: RecordingProtectionCriticalSectionLock(),
            notifier: RecordingProtectionSignalNotifier()
        )

        let first = try writer.publish(.pauseStateChanged)
        let second = try writer.publish(.pauseStateChanged)

        XCTAssertEqual(try reader.receiveWakeup(.pauseStateChanged, observedRevision: second.revision), .delivered(second))

        let third = try writer.publish(.pauseStateChanged)

        XCTAssertEqual(try reader.receiveWakeup(.pauseStateChanged, observedRevision: first.revision), .delivered(third))
    }
}
