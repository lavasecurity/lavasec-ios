import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable tests for the pinned-language `LavaCoreStrings` variants (incident plan
/// Phase 3): the Live Activity widget renders out-of-process in the SYSTEM language, so
/// its strings resolve through the shared `LavaNotificationLanguage` pin via the same
/// direct-`.lproj` mechanism the notification posters use. Values assert against the
/// committed catalogs in `Sources/LavaSecKit/Resources/*.lproj/Localizable.strings`.
final class LavaCoreStringsTests: XCTestCase {
    func testShippingWireGuardRecoveryCopyResolvesInEveryTranslatedLanguage() {
        let keys = [
            "Couldn't open that file. Try moving it to Files first.",
            "That file isn't text, so it isn't a WireGuard config.",
            "This build can't save a WireGuard configuration. Update Lava and try again.",
            "This WireGuard configuration uses a setting Lava doesn't support.",
            "A required WireGuard setting is missing or repeated.",
            "A WireGuard setting is in the wrong section.",
            "A WireGuard setting has an invalid value.",
            "This WireGuard configuration isn't valid. Check its addresses, routes, MTU, and public key.",
            "Your WireGuard configuration couldn't be read. Try again after unlocking your device.",
            "The saved WireGuard configuration is no longer usable. Import it again.",
            "Lava couldn't access the saved WireGuard keys. Unlock your device and try again.",
            "Lava couldn't save the WireGuard configuration. Try again in a moment.",
            "The WireGuard private key isn't valid. Import your configuration again.",
            "The WireGuard pre-shared key isn't valid. Import your configuration again.",
            "This WireGuard configuration uses the server's key. Import your device's configuration instead."
        ]
        for language in ["ja", "zh-Hant", "zh-Hans", "de", "fr", "es", "ko", "pt-BR", "it"] {
            for key in keys {
                let value = LavaCoreStrings.localized(key, languageCode: language)
                XCTAssertFalse(value.isEmpty, "\(key)/\(language)")
                XCTAssertNotEqual(value, key, "WireGuard copy must resolve from the package bundle: \(key)/\(language)")
            }
            let size = LavaCoreStrings.localizedFormat(
                "That file is %lld KB — far too big for a WireGuard config. Wrong file?", languageCode: language, 128)
            XCTAssertTrue(size.contains("128"), language)
            XCTAssertFalse(size.contains("%lld"), language)
            XCTAssertFalse(size.contains("That file is"), language)
        }
    }

    func testShippingWireGuardErrorsDoNotExposeDiagnosticPayloads() {
        let marker = "PRIVATE_CONFIGURATION_SENTINEL"
        let storeFailures: [ChainedUpstreamSecretStoreFailure] = [
            .configurationUnreadable(marker), .configurationUnusable, .keychainRefused(-12345),
            .entropyUnavailable, .malformedPrivateKey, .malformedPresharedKey,
            .unusablePrivateKey, .privateKeyBelongsToThePeer, .accessGroupUnavailable,
            .writerExclusionUnavailable
        ]
        let parserFailures: [ChainedUpstreamStagingRefusal] = [
            .buildMayNotStage(.production), .buildIdentityIsInconsistent(identity: .qa, group: marker),
            .unsupportedDirective(marker), .missingOrRepeatedKey(marker),
            .directiveInWrongSection(directive: marker, section: marker), .malformedValue(marker),
            .configurationRefused(.malformedAllowedIPs), .rotationRefused(.malformedPrivateKey)
        ]
        for failure in storeFailures {
            XCTAssertFalse(failure.localizedDescription.contains(marker))
            XCTAssertFalse(failure.localizedDescription.contains("-12345"))
            XCTAssertFalse(failure.localizedDescription.contains("ChainedUpstreamSecretStoreFailure"))
            XCTAssertFalse(failure.localizedDescription.isEmpty)
        }
        for failure in parserFailures {
            XCTAssertFalse(failure.localizedDescription.contains(marker))
            XCTAssertFalse(failure.localizedDescription.contains("ChainedUpstreamStagingRefusal"))
            XCTAssertFalse(failure.localizedDescription.isEmpty)
        }
    }

    func testSharedErrorAndBackupCopyResolvesInEveryShippedLanguage() {
        let languages = ["ja", "zh-Hant", "zh-Hans", "de", "fr", "es", "ko", "pt-BR", "it"]
        let keys = [
            "Choose a valid DNS provider and transport.",
            "The Supabase Auth response was not valid.",
            "This domain will be blocked after you save.",
            "Encrypted locally. Sign in to upload."
        ]
        for language in languages {
            for key in keys {
                let value = LavaCoreStrings.localized(key, languageCode: language)
                XCTAssertFalse(value.isEmpty, "\(key)/\(language)")
                XCTAssertNotEqual(value, key, "Shared copy must resolve from the package bundle: \(key)/\(language)")
            }
            let size = LavaCoreStrings.localizedFormat("Latest encrypted settings backup size is %@.", languageCode: language, "42 KB")
            XCTAssertTrue(size.contains("42 KB"), language)
            XCTAssertFalse(size.contains("%@"), language)
            let domain = LavaCoreStrings.localizedFormat("Added %@", languageCode: language, "example.com")
            XCTAssertTrue(domain.contains("example.com"), language)
        }
    }

    func testLocalizedWithLanguageCodeSelectsThePinnedLProjIndependentOfProcessLocale() {
        // The whole point of the pin: an explicit languageCode selects the matching
        // .lproj regardless of the running process's locale — Foundation's bundle lookup
        // would refuse a non-preferred .lproj, which is exactly the widget's stuck-English
        // failure the pin exists to fix.
        XCTAssertEqual(
            LavaCoreStrings.localized("widget.state.on", languageCode: "de"),
            "Lava ist aktiviert"
        )
        XCTAssertEqual(
            LavaCoreStrings.localized("widget.state.on", languageCode: "zh-Hant"),
            "Lava 已開啟"
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
