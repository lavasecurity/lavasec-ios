import XCTest
@testable import LavaSecCore

final class SecurityPolicyTests: XCTestCase {
    func testProtectedSurfacesSeparateSettingsFromBlocklistEditing() {
        XCTAssertEqual(
            SecurityProtectedSurface.allCases.map(\.rawValue),
            [
                "appUnlock",
                "protectionControl",
                "protectionPause",
                "filterEditing",
                "activityViewing",
                "appSettings"
            ]
        )
    }

    func testAccessPolicyCanDeclareReadOnlyOrRequiredSurface() {
        XCTAssertEqual(SecurityAccessPolicy.readOnly.requiredSurface, nil)
        XCTAssertEqual(SecurityAccessPolicy.requires(.appSettings).requiredSurface, .appSettings)
        XCTAssertEqual(SecurityAccessPolicy.requires(.filterEditing).requiredSurface, .filterEditing)
    }
}
