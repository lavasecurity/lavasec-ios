import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class LiveActivityPausePreferenceTests: XCTestCase {
    func testDefaultsToFiveMinutesWhenUnset() {
        let store = FakeProtectionKeyValueStore()
        XCTAssertEqual(LiveActivityPausePreference.minutes(from: store), 5)
        XCTAssertEqual(LiveActivityPausePreference.defaultMinutes, 5)
    }

    func testRangeIsOneToThirtyMinutes() {
        XCTAssertEqual(LiveActivityPausePreference.minimumMinutes, 1)
        XCTAssertEqual(LiveActivityPausePreference.maximumMinutes, 30)
        XCTAssertEqual(LiveActivityPausePreference.minutesRange, 1...30)
    }

    func testClampHoldsValuesInsideTheValidRange() {
        XCTAssertEqual(LiveActivityPausePreference.clamp(0), 1)
        XCTAssertEqual(LiveActivityPausePreference.clamp(-5), 1)
        XCTAssertEqual(LiveActivityPausePreference.clamp(1), 1)
        XCTAssertEqual(LiveActivityPausePreference.clamp(17), 17)
        XCTAssertEqual(LiveActivityPausePreference.clamp(30), 30)
        XCTAssertEqual(LiveActivityPausePreference.clamp(31), 30)
        XCTAssertEqual(LiveActivityPausePreference.clamp(600), 30)
    }

    func testSetMinutesRoundTripsThroughStorageAndClamps() {
        let store = FakeProtectionKeyValueStore()

        LiveActivityPausePreference.setMinutes(20, in: store)
        XCTAssertEqual(LiveActivityPausePreference.minutes(from: store), 20)
        XCTAssertEqual(store.integer(forKey: LiveActivityPausePreference.defaultsKeyName), 20)

        // An out-of-range write can never widen the off-protection window.
        LiveActivityPausePreference.setMinutes(45, in: store)
        XCTAssertEqual(LiveActivityPausePreference.minutes(from: store), 30)

        LiveActivityPausePreference.setMinutes(0, in: store)
        XCTAssertEqual(LiveActivityPausePreference.minutes(from: store), 1)
    }

    func testMinutesClampsAStaleOutOfRangeStoredValueOnRead() {
        let store = FakeProtectionKeyValueStore()
        // A value written by some other path that bypassed setMinutes.
        store.set(99, forKey: LiveActivityPausePreference.defaultsKeyName)
        XCTAssertEqual(LiveActivityPausePreference.minutes(from: store), 30)
    }

    func testDurationConvertsClampedMinutesToSeconds() {
        XCTAssertEqual(LiveActivityPausePreference.duration(forMinutes: 5), 300)
        XCTAssertEqual(LiveActivityPausePreference.duration(forMinutes: 1), 60)
        XCTAssertEqual(LiveActivityPausePreference.duration(forMinutes: 30), 1800)
        XCTAssertEqual(LiveActivityPausePreference.duration(forMinutes: 0), 60)
        XCTAssertEqual(LiveActivityPausePreference.duration(forMinutes: 100), 1800)
    }
}
