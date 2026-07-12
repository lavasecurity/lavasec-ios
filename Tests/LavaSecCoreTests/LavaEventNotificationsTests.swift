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

    func testForegroundPublicationTrustsOnlyFreshAsserts() {
        let defaults = makeDefaults()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(LavaAppForegroundPublication.isForegroundActive(in: defaults, at: t0),
                       "Absent flag ⇒ not foreground.")

        LavaAppForegroundPublication.publish(true, to: defaults, at: t0)
        XCTAssertTrue(LavaAppForegroundPublication.isForegroundActive(in: defaults, at: t0))
        XCTAssertTrue(LavaAppForegroundPublication.isForegroundActive(
            in: defaults,
            at: t0.addingTimeInterval(LavaAppForegroundPublication.maxTrustedAge - 1)
        ))

        // The age-out: a crash/jetsam of a visible app clears nothing, and the next process to run can
        // be the Focus extension (which must not clear the flag itself) — a stale assert must stop
        // suppressing banners on its own (Codex review #361).
        XCTAssertFalse(LavaAppForegroundPublication.isForegroundActive(
            in: defaults,
            at: t0.addingTimeInterval(LavaAppForegroundPublication.maxTrustedAge)
        ))

        LavaAppForegroundPublication.publish(false, to: defaults, at: t0)
        XCTAssertFalse(LavaAppForegroundPublication.isForegroundActive(in: defaults, at: t0))
        XCTAssertNil(defaults.object(forKey: LavaAppForegroundPublication.stampDefaultsKeyName),
                     "Clearing the flag must drop the stamp (a cleared flag needs no age).")
    }

    func testForegroundStampFromTheFutureIsNotTrusted() {
        // A backward clock correction after an assert leaves a FUTURE stamp. Trusting its negative age
        // would stretch the post-crash suppression cap until wall time catches up, so it must read as
        // NOT foreground — self-healing on the next scene .active re-stamp (Codex review #361).
        let defaults = makeDefaults()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        LavaAppForegroundPublication.publish(true, to: defaults, at: t0)
        XCTAssertFalse(LavaAppForegroundPublication.isForegroundActive(in: defaults, at: t0.addingTimeInterval(-1)))
        XCTAssertTrue(LavaAppForegroundPublication.isForegroundActive(in: defaults, at: t0),
                      "Zero age (assert instant) must still be trusted.")
    }

    func testForegroundFlagWithoutStampIsNotTrusted() {
        // A pre-stamp app version's leftover write is a bare true flag. Trusting it would recreate the
        // stuck-flag suppression the stamp exists to prevent, so it must read as NOT foreground.
        let defaults = makeDefaults()
        defaults.set(true, forKey: LavaAppForegroundPublication.flagDefaultsKeyName)
        XCTAssertFalse(LavaAppForegroundPublication.isForegroundActive(in: defaults))
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
        // strings from de/ja/zh-Hans .lproj (see Sources/LavaSecKit/Resources/*.lproj/Localizable.strings).
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
