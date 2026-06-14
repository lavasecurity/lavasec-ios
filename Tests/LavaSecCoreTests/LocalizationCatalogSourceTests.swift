import XCTest

final class LocalizationCatalogSourceTests: XCTestCase {
    func testLocalizableCatalogDoesNotMarkManualKeysStale() throws {
        let catalog = try Self.catalog(named: "Localizable.xcstrings")
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

    private static func catalog(named fileName: String) throws -> [String: Any] {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = packageRootURL
            .appendingPathComponent("LavaSecApp")
            .appendingPathComponent(fileName)
        let data = try Data(contentsOf: catalogURL)

        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
