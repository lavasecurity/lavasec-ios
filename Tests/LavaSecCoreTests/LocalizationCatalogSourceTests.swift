import XCTest

final class LocalizationCatalogSourceTests: XCTestCase {
    func testLocalizableCatalogDoesNotMarkManualKeysStale() throws {
        let catalog = try Self.catalog(.localizableStringsCatalog)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let staleKeys = strings
            .filter { $0.value["extractionState"] as? String == "stale" }
            .map(\.key)
            .sorted()

        XCTAssertTrue(
            staleKeys.isEmpty,
            "Manual keys used through LavaStrings should not be marked stale: \(staleKeys.prefix(10))"
        )
    }

    func testPlusBillingOptionCatalogIncludesDynamicPaywallKeys() throws {
        let catalog = try Self.catalog(.localizableStringsCatalog)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let expectedAppLocales = try Self.expectedAppLocales()

        for key in [
            "Yearly, paid monthly",
            "Lower monthly payment",
            "\"If we commit for 12 months, each month is cheaper.\"",
            "\"We are saving %d%%! This has the best value.\"",
            "\"Paying by the year beats paying by the month.\"",
            "Family Sharing",
            "%@ total"
        ] {
            let localizations = try XCTUnwrap(
                strings[key]?["localizations"] as? [String: Any],
                "Missing localization catalog key: \(key)"
            )
            XCTAssertEqual(
                Set(localizations.keys),
                expectedAppLocales,
                "Localization key \(key) must include every app locale because the generic string coverage script cannot see dynamic lavaLocalized paywall keys."
            )
        }
    }

    func testFeedbackReviewAndSubmitCatalogKeysCoverAllLocales() throws {
        let catalog = try Self.catalog(.localizableStringsCatalog)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let expectedAppLocales = try Self.expectedAppLocales()

        // The bug-report review echo and submit button feed dynamic Strings through
        // .lavaLocalized, so the generic string-coverage script can't see them — pin these
        // keys manually with every app locale so "Not provided"/"Submit" never render
        // English-only in a translated build.
        for key in [
            "Submit",
            "Retry",
            "Submitting",
            "Not provided",
            "Not selected",
            "Sent",
            "Not sent"
        ] {
            let localizations = try XCTUnwrap(
                strings[key]?["localizations"] as? [String: Any],
                "Missing localization catalog key: \(key)"
            )
            XCTAssertEqual(
                Set(localizations.keys),
                expectedAppLocales,
                "Localization key \(key) must include every app locale."
            )
        }
    }

    func testRetryableFilterSaveAndSwitchFailuresCoverAllLocales() throws {
        let catalog = try Self.catalog(.localizableStringsCatalog)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let expectedAppLocales = try Self.expectedAppLocales()

        for key in [
            "That filter changed while it was being prepared. Try again.",
            "This filter is now active. Review your changes, then save again."
        ] {
            let localizations = try XCTUnwrap(
                strings[key]?["localizations"] as? [String: Any],
                "The retryable filter failure is rendered through message.lavaLocalized and must be registered: \(key)"
            )

            XCTAssertEqual(Set(localizations.keys), expectedAppLocales)
        }
    }

    func testChainedStartupFailureMessageCoversAllLocales() throws {
        let catalog = try Self.catalog(.localizableStringsCatalog)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let expectedAppLocales = try Self.expectedAppLocales()
        // Both are dynamic `.lavaLocalized` chained-failure lines the string-coverage script
        // cannot see: the terminal surrender message, and the refusal shown when an explicit
        // Guard retry cannot advance the marker it is gated on.
        for key in [
            "DNS filtering is on. Reconnect to retry VPN forwarding.",
            "Lava could not clear the previous VPN chaining failure. Try again in a moment."
        ] {
            let localizations = try XCTUnwrap(
                strings[key]?["localizations"] as? [String: Any],
                "The terminal chained failure is rendered through .lavaLocalized and must be registered: \(key)"
            )

            XCTAssertEqual(
                Set(localizations.keys),
                expectedAppLocales,
                "The terminal chained failure must be translated in every app locale: \(key)")
        }
    }

    func testGuardVerificationAndDynamicActionsCoverEveryLocale() throws {
        let catalog = try Self.catalog(.localizableStringsCatalog)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for key in ["Reconnecting VPN", "Lava is restoring VPN forwarding.", "Checking VPN", "Waiting for traffic to confirm VPN forwarding.",
                    "Turn on", "Turn off", "Reconnect", "Resume now", "Protection off",
                    "Starting local filtering.", "Stopping local filtering.",
                    "Turn on local protection when you are ready.", "Turn on to set up protection.",
                    "Lava can't confirm whether protection is active."] {
            let localizations = try XCTUnwrap(strings[key]?["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), try Self.expectedAppLocales(), key)
        }
    }

    private static func catalog(_ sourceFile: SourceFile) throws -> [String: Any] {
        let data = try Data(contentsOf: sourceFileURL(sourceFile))

        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private static func expectedAppLocales() throws -> Set<String> {
        let manifest = try catalog(.supportedLocalesManifest)
        return Set(try XCTUnwrap(manifest["locales"] as? [String]))
    }
}
