import XCTest
@testable import LavaSecCore

final class LavaEventNotificationsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "notif-prefs-\(UUID().uuidString)")!
    }

    func testEveryCategoryDefaultsOnWhenUnset() {
        let defaults = makeDefaults()
        for category in LavaNotificationCategory.allCases {
            XCTAssertTrue(
                LavaNotificationPreferences.isEnabled(category, in: defaults),
                "\(category.rawValue) must default ON (a fresh install opts into every category)."
            )
        }
    }

    func testSetEnabledRoundTrips() {
        let defaults = makeDefaults()
        for category in LavaNotificationCategory.allCases {
            LavaNotificationPreferences.setEnabled(false, for: category, in: defaults)
            XCTAssertFalse(LavaNotificationPreferences.isEnabled(category, in: defaults))
            LavaNotificationPreferences.setEnabled(true, for: category, in: defaults)
            XCTAssertTrue(LavaNotificationPreferences.isEnabled(category, in: defaults))
        }
    }

    func testCategoriesHaveDistinctDefaultsKeys() {
        let keys = LavaNotificationCategory.allCases.map(\.enabledDefaultsKey)
        XCTAssertEqual(keys.count, Set(keys).count, "Each category must map to a distinct defaults key.")
        // One toggle must not leak into another's state.
        let defaults = makeDefaults()
        LavaNotificationPreferences.setEnabled(false, for: .filterChanged, in: defaults)
        XCTAssertFalse(LavaNotificationPreferences.isEnabled(.filterChanged, in: defaults))
        XCTAssertTrue(LavaNotificationPreferences.isEnabled(.connectivity, in: defaults),
                      "Disabling one category must not disable another.")
    }

    func testFilterSwitchBodyIsLocalizedAndInterpolatesName() {
        // Resolves against the package's Bundle.module catalog (the en .lproj) and interpolates the filter
        // name. Also proves the SwiftPM resource bundle is found (a missing bundle would return the key).
        XCTAssertEqual(
            LavaEventNotificationPoster.filterSwitchBody(committed: true, filterName: "Work"),
            "Filter switched to Work"
        )
        XCTAssertEqual(
            LavaEventNotificationPoster.filterSwitchBody(committed: false, filterName: "Work"),
            "Couldn't switch to Work"
        )
    }
}
