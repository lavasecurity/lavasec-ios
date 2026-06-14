import XCTest

final class AppPrivacyShieldSourceTests: XCTestCase {
    func testAppAddsPrivacyShieldBeforeInactiveSnapshots() throws {
        let appSource = try Self.source(named: "LavaSecApp.swift", in: "LavaSecApp")

        XCTAssertTrue(appSource.contains("private let privacyShield = LavaPrivacyShield()"))
        XCTAssertTrue(appSource.contains("func applicationWillResignActive"))
        XCTAssertTrue(appSource.contains("func applicationDidEnterBackground"))
        XCTAssertTrue(appSource.contains("privacyShield.show(in: application)"))
    }

    func testPrivacyShieldSettlesCurrentUIBeforeSnapshot() throws {
        let appSource = try Self.source(named: "LavaSecApp.swift", in: "LavaSecApp")

        XCTAssertTrue(appSource.contains("application.sendAction(#selector(UIResponder.resignFirstResponder)"))
        XCTAssertTrue(appSource.contains("window.layoutIfNeeded()"))
    }

    func testAppRemovesPrivacyShieldWhenActiveAgain() throws {
        let appSource = try Self.source(named: "LavaSecApp.swift", in: "LavaSecApp")

        XCTAssertTrue(appSource.contains("func applicationDidBecomeActive"))
        XCTAssertTrue(appSource.contains("privacyShield.hide(from: application)"))
    }

    func testPrivacyShieldCoversWindowsWithBlurredMaterial() throws {
        let appSource = try Self.source(named: "LavaSecApp.swift", in: "LavaSecApp")

        XCTAssertTrue(appSource.contains("final class LavaPrivacyShield"))
        XCTAssertTrue(appSource.contains("UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))"))
        XCTAssertTrue(appSource.contains("overlay.frame = window.bounds"))
        XCTAssertTrue(appSource.contains("window.addSubview(overlay)"))
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
