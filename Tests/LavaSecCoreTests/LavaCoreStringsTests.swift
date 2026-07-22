import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable tests for the pinned-language `LavaCoreStrings` variants (incident plan
/// Phase 3): the Live Activity widget renders out-of-process in the SYSTEM language, so
/// its strings resolve through the shared `LavaNotificationLanguage` pin via the same
/// direct-`.lproj` mechanism the notification posters use. Values assert against the
/// committed catalogs in `Sources/LavaSecKit/Resources/*.lproj/Localizable.strings`.
final class LavaCoreStringsTests: XCTestCase {
    func testLocalizedWithLanguageCodeSelectsThePinnedLProjIndependentOfProcessLocale() {
        // The whole point of the pin: an explicit languageCode selects the matching
        // .lproj regardless of the running process's locale — Foundation's bundle lookup
        // would refuse a non-preferred .lproj, which is exactly the widget's stuck-English
        // failure the pin exists to fix.
        XCTAssertEqual(
            LavaCoreStrings.localized("widget.state.on", languageCode: "de"),
            "Lava Security ist aktiviert"
        )
        XCTAssertEqual(
            LavaCoreStrings.localized("widget.state.on", languageCode: "zh-Hant"),
            "Lava Security 已開啟"
        )
        // The trailing space is deliberate and load-bearing (render rescue for short space-less
        // ja values in the Live Activity button — see the ja catalog comment); this assertion
        // pins it so a well-meaning trim doesn't silently reintroduce the "…" collapse.
        XCTAssertEqual(
            LavaCoreStrings.localized("widget.action.resume", languageCode: "ja"),
            "再開 "
        )
    }

    func testLocalizedWithUnknownOrNilLanguageFallsBackToAmbient() {
        // nil (no pin published — e.g. a pre-unlock render reading the locked suite as
        // empty) and an unresolvable code both fall back to the ambient Bundle.module
        // resolution — never the raw key. Ambient resolution in the test process must
        // match the one-argument variant the widget used before the pin.
        XCTAssertEqual(
            LavaCoreStrings.localized("widget.state.on", languageCode: nil),
            LavaCoreStrings.localized("widget.state.on")
        )
        XCTAssertEqual(
            LavaCoreStrings.localized("widget.state.on", languageCode: "xx-Fake"),
            LavaCoreStrings.localized("widget.state.on")
        )
        XCTAssertFalse(
            LavaCoreStrings.localized("widget.state.on", languageCode: nil).isEmpty
        )
        XCTAssertNotEqual(
            LavaCoreStrings.localized("widget.state.on", languageCode: nil),
            "widget.state.on"
        )
    }

    func testLocalizedFormatWithLanguageCodeFormatsThePinnedTemplate() {
        // The template resolves in the pinned language; the argument substitution uses the
        // current locale's number formatting, matching the notification posters.
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("widget.action.pauseForMinutes", languageCode: "de", 5),
            "Für 5 Min. pausieren"
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("widget.action.pauseForMinutes", languageCode: "zh-Hant", 10),
            "暫停 10 分鐘"
        )
    }

    func testLocalizedFormatResolvesTheDurationOnlyShortPauseLabel() {
        // The Live Activity Pause button draws the duration-only short label — the pause.fill glyph
        // carries the verb, so the longer full phrase ("15 分間一時停止" etc.) no longer truncates in
        // the squeezed action row. The full phrase stays the VoiceOver label (asserted above). Each
        // locale keeps its own minute form; digits follow the device region via String(format:).
        // The TRAILING space is deliberate and load-bearing (same render rescue as the ja resume
        // value — see the ja catalog comment). The internally-spaced "15 分" variant regressed to
        // "15…" on device: its internal space created a break point whose final bare-分 segment
        // collapsed like the unspaced values did. This pins the exact working form.
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("widget.action.pauseForMinutesShort", languageCode: "ja", 15),
            "15分 "
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("widget.action.pauseForMinutesShort", languageCode: "de", 5),
            "5 Min."
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("widget.action.pauseForMinutesShort", languageCode: "zh-Hant", 30),
            "30 分鐘"
        )
        XCTAssertEqual(
            LavaCoreStrings.localizedFormat("widget.action.pauseForMinutesShort", languageCode: "en", 10),
            "10 min"
        )
    }
}
