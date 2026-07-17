import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable proof for the Switch Filter App Intent's result-dialog localization
/// (`LavaSecApp/SwitchFilterShortcut.swift`). The dialog and the thrown disallowed error are rendered
/// OUT OF PROCESS by Shortcuts/Siri, so a bare `LocalizedStringResource` resolves in the SYSTEM locale
/// and renders English for a user whose app runs in another language (an iOS per-app override, or a device
/// whose system language differs from the app's) — the Switch-Filter twin of the 2026-07-14 Live Activity
/// "stuck-English" incident (lavasec-infra
/// `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`, Phase 3). The intent now PRE-RESOLVES
/// each string in the app process against the pinned app language via `LavaCoreStrings.localizedFormat`, so
/// Shortcuts renders the app-language text verbatim.
///
/// These tests run in an English test process yet assert the app-language values, which is the whole point:
/// the pinned `.lproj` must be selected independent of the running process's locale. The filter NAME is a
/// `%@` placeholder; the built-in level names (Core / Balanced / Extra) and "Lava" stay English in every
/// locale by design (guard-tab/brand rule), so only the surrounding sentence localizes. Values assert against
/// the committed catalogs in `Sources/LavaSecKit/Resources/*.lproj/Localizable.strings`.
final class SwitchFilterDialogLocalizationTests: XCTestCase {
    /// The exact user-reported scenario: an automation runs Switch Filter, the built-in "Extra" filter is
    /// already active, and a zh-Hant app must show the Chinese sentence — not English. Before the fix this
    /// dialog resolved in the (English) system locale; this pins that it now resolves in the app's language.
    func testAlreadyActiveDialogResolvesInPinnedLanguageIndependentOfProcessLocale() {
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterAlreadyActive", languageCode: "zh-Hant", "Extra"),
            "Extra 已經是目前生效的篩選器。"
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterAlreadyActive", languageCode: "ja", "Extra"),
            "Extra はすでに有効なフィルターです。"
        )
        // en (the source language) reads naturally, with the built-in level name staying English.
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterAlreadyActive", languageCode: "en", "Extra"),
            "Extra is already your active filter."
        )
    }

    /// The committed ("Switched to …") and deferred ("… will apply automatically") dialogs
    /// resolve in the pinned language too — the other two `.result(dialog:)` arms of `perform()`.
    func testCommittedAndDeferredDialogsResolveInPinnedLanguage() {
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterSwitchedTo", languageCode: "zh-Hant", "Balanced"),
            "已切換至 Balanced。"
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterWillApplyAutomatically", languageCode: "zh-Hant", "Core"),
            "Core 將自動生效。"
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterSwitchedTo", languageCode: "de", "Balanced"),
            "Zu Balanced gewechselt."
        )
    }

    /// The disallowed path throws `SwitchFilterDisallowedError`, whose message is pre-resolved in `perform()`
    /// for the same reason (its `localizedStringResource` may be read in the Shortcuts process, which cannot
    /// read the pin). Its `dialog.filterSwitchDisallowed` copy must localize identically.
    func testDisallowedErrorMessageResolvesInPinnedLanguage() {
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterSwitchDisallowed", languageCode: "zh-Hant", "Extra"),
            "無法切換至 Extra。請開啟 Lava 檢查你的篩選器設定。"
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("dialog.filterSwitchDisallowed", languageCode: "en", "Extra"),
            "Couldn't switch to Extra. Open Lava to check your filter settings."
        )
    }

    /// Regression guard for the reported bug across the whole surface: requesting a non-English pin must
    /// return a TRANSLATED sentence — never the English source (the old system-locale behavior) and never the
    /// raw key — for every `dialog.*` key and every shipped non-English locale (parity with the notification
    /// catalog).
    func testEveryDialogKeyIsTranslatedInEveryLocaleAndNeverLeaksTheRawKey() {
        let keys = [
            "dialog.filterSwitchedTo", "dialog.filterAlreadyActive",
            "dialog.filterWillApplyAutomatically", "dialog.filterSwitchDisallowed",
        ]
        let nonEnglish = ["de", "es", "fr", "it", "ja", "ko", "pt-BR", "zh-Hans", "zh-Hant"]
        for key in keys {
            let english = LavaCoreStrings.localizedFormat(key, languageCode: "en", "Work")
            XCTAssertFalse(english.isEmpty, "\(key): en must resolve.")
            XCTAssertNotEqual(english, key, "\(key): en must resolve, not leak the raw key.")
            XCTAssertTrue(english.contains("Work"), "\(key): the filter name must be interpolated.")
            for locale in nonEnglish {
                let value = LavaCoreStrings.localizedFormat(key, languageCode: locale, "Work")
                XCTAssertFalse(value.isEmpty, "\(key)/\(locale): must resolve.")
                XCTAssertNotEqual(value, key, "\(key)/\(locale): must not leak the raw key.")
                XCTAssertNotEqual(
                    value, english,
                    "\(key)/\(locale): must be TRANSLATED, not the English source (the stuck-English bug)."
                )
                XCTAssertTrue(value.contains("Work"), "\(key)/\(locale): the filter name must be interpolated.")
            }
        }
    }

    /// A nil pin (no post-unlock foreground yet — the locked shared suite reads back no code) and an
    /// unresolvable code both fall back to the ambient `Bundle.module` resolution, never the raw key. Ambient
    /// is English in the test process — the same fallback the banner posters and the Live Activity widget use.
    func testUnknownOrNilPinFallsBackToAmbientNeverRawKey() {
        for languageCode in [nil, "xx-Fake"] as [String?] {
            XCTAssertEqual(
                LavaCoreStrings.localizedFormat("dialog.filterAlreadyActive", languageCode: languageCode, "Work"),
                "Work is already your active filter."
            )
        }
    }
}
