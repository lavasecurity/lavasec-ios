import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

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

    func testFilterSwitchBodyHonorsPinnedLanguageIndependentOfProcessLocale() {
        // The whole point of the pin: an explicit languageCode selects the matching .lproj regardless of the
        // running process's locale, so an extension/tunnel renders in the app's language. Uses the committed
        // strings from de/ja/zh-Hans .lproj (see Sources/LavaSecCore/Resources/*.lproj/Localizable.strings).
        XCTAssertEqual(
            LavaEventNotificationPoster.filterSwitchBody(committed: true, filterName: "Work", languageCode: "de"),
            "Filter zu Work gewechselt"
        )
        XCTAssertEqual(
            LavaEventNotificationPoster.filterSwitchBody(committed: false, filterName: "Work", languageCode: "ja"),
            "Workに切り替えできませんでした"
        )
        XCTAssertEqual(
            LavaEventNotificationPoster.filterSwitchBody(committed: true, filterName: "Work", languageCode: "zh-Hans"),
            "已将过滤器切换到 Work"
        )
    }

    func testFilterSwitchBodyFallsBackToAmbientForUnknownOrNilLanguage() {
        // An unresolvable code (no such .lproj) or nil falls back to the ambient Bundle.module resolution —
        // never returns the raw key. In the test process ambient resolution is English.
        XCTAssertEqual(
            LavaEventNotificationPoster.filterSwitchBody(committed: true, filterName: "Work", languageCode: "xx-Fake"),
            "Filter switched to Work"
        )
        XCTAssertEqual(
            LavaEventNotificationPoster.filterSwitchBody(committed: true, filterName: "Work", languageCode: nil),
            "Filter switched to Work"
        )
    }

    func testNotificationLanguagePinRoundTripsAndClears() {
        let defaults = makeDefaults()
        XCTAssertNil(LavaNotificationLanguage.pinnedCode(in: defaults), "Absent by default.")

        LavaNotificationLanguage.publish("zh-Hans", to: defaults)
        XCTAssertEqual(LavaNotificationLanguage.pinnedCode(in: defaults), "zh-Hans")

        // Empty and nil both clear the pin (posters then fall back to ambient resolution).
        LavaNotificationLanguage.publish("", to: defaults)
        XCTAssertNil(LavaNotificationLanguage.pinnedCode(in: defaults))
        LavaNotificationLanguage.publish("ja", to: defaults)
        LavaNotificationLanguage.publish(nil, to: defaults)
        XCTAssertNil(LavaNotificationLanguage.pinnedCode(in: defaults))
    }

    func testCurrentAppLocalizationIsABundledLocale() {
        // Whatever the process resolves to must be one the package can actually load, so a pin published from
        // it always has a matching .lproj for the posters.
        let code = try? XCTUnwrap(LavaNotificationLanguage.currentAppLocalization())
        if let code {
            XCTAssertNotNil(
                Bundle.module.path(forResource: code, ofType: "lproj"),
                "currentAppLocalization() must be a bundled localization; got \(code)."
            )
        }
    }
}
