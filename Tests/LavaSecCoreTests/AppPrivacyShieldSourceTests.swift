import XCTest

final class AppPrivacyShieldSourceTests: XCTestCase {
    func testAppAddsPrivacyShieldBeforeInactiveSnapshots() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("private let privacyShield = LavaPrivacyShield()"))
        XCTAssertTrue(appSource.contains("func applicationWillResignActive"))
        XCTAssertTrue(appSource.contains("func applicationDidEnterBackground"))
        XCTAssertTrue(appSource.contains("privacyShield.show(in: application)"))
    }

    func testPrivacyShieldSettlesCurrentUIBeforeSnapshot() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("application.sendAction(#selector(UIResponder.resignFirstResponder)"))
        XCTAssertTrue(appSource.contains("window.layoutIfNeeded()"))
    }

    func testAppRemovesPrivacyShieldWhenActiveAgain() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("func applicationDidBecomeActive"))
        XCTAssertTrue(appSource.contains("privacyShield.hide(from: application)"))
    }

    func testPrivacyShieldCoversWindowsWithBlurredMaterial() throws {
        let appSource = try readSource(.lavaSecApp)

        XCTAssertTrue(appSource.contains("final class LavaPrivacyShield"))
        XCTAssertTrue(appSource.contains("UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))"))
        XCTAssertTrue(appSource.contains("overlay.frame = window.bounds"))
        XCTAssertTrue(appSource.contains("window.addSubview(overlay)"))
    }
}
