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
