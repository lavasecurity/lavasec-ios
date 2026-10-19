import XCTest

final class UIScaffoldMaintenanceSourceTests: XCTestCase {

    func testRetiredSettingsNavigationRowsAreRemoved() throws {
        let settings = try readSource(.settingsView)
        XCTAssertFalse(settings.contains("private struct SettingsNavigationRow"))
        XCTAssertFalse(settings.contains("struct SettingsView: View"))
        XCTAssertFalse(settings.contains("path: $path,"))
    }

    // Auto-switch instructions and their React route wiring are asserted by
    // FocusFilterIntentWiringSourceTests; rationale wording is not an API contract.
}
