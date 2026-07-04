import XCTest

final class LocalizationCatalogSourceTests: XCTestCase {
    /// Must stay in sync with the project's supported locales
    /// (see Sources/LavaSecCore/Resources/*.lproj).
    private static let expectedAppLocales: Set<String> = [
        "de",
        "en",
        "es",
        "fr",
        "it",
        "ja",
        "ko",
        "pt-BR",
        "zh-Hans",
        "zh-Hant"
    ]

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
                Self.expectedAppLocales,
                "Localization key \(key) must include every app locale because the generic string coverage script cannot see dynamic lavaLocalized paywall keys."
            )
        }
    }

    private static func catalog(_ sourceFile: SourceFile) throws -> [String: Any] {
        let data = try Data(contentsOf: sourceFileURL(sourceFile))

        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
