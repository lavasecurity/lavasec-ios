import XCTest

/// Pins the app-only construction boundary, which the package test target cannot import.
/// Notification delivery and haptic policy remain covered by their executable Kit tests.
final class AppPlatformCompositionSourceTests: XCTestCase {
    private func index(of needle: String, in source: String) throws -> String.Index {
        try XCTUnwrap(source.range(of: needle), "Missing source anchor: \(needle)").lowerBound
    }

    func testPlatformEffectsAreInjectedBeforeConfigurationLoads() throws {
        let model = try readSource(.appViewModelCore)
        let construction = try index(of: "let services = platformServices ?? .live()", in: model)
        let notifications = try index(of: "protectionUserNotifications = services.protectionNotifications", in: model)
        let ambient = try index(of: "liveActivityController = services.ambientProtection", in: model)
        let load = try index(of: "        loadPersistedConfiguration()", in: model)
        XCTAssertLessThan(construction, notifications)
        XCTAssertLessThan(notifications, load)
        XCTAssertLessThan(ambient, load)
        XCTAssertTrue(model.contains("let protectionUserNotifications: any ProtectionNotificationPresenting"))
        XCTAssertFalse(model.contains("ProtectionUserNotificationController()"))
        XCTAssertFalse(model.contains("LavaLiveActivityController()"))
        XCTAssertFalse(model.contains("import CoreHaptics"))
        XCTAssertFalse(model.contains("import UserNotifications"))
    }

    func testLiveCompositionDoesNotActivateForegroundEffects() throws {
        let composition = try readSource(.appPlatformServices)
        XCTAssertTrue(composition.contains("protectionNotifications: ProtectionUserNotificationController()"))
        XCTAssertTrue(composition.contains("ambientProtection: LavaLiveActivityController()"))
        let factory = try sourceBlock(in: composition, startingAt: "static func live()", endingBefore: nil)
        for effect in ["requestAuthorization(", "startObservingAuthorizationChanges(", "reconcile(", "Task {"] {
            XCTAssertFalse(factory.contains(effect), "Construction must not activate \(effect)")
        }
        let shortcuts = try readSource(.protectionShortcuts)
        XCTAssertTrue(shortcuts.contains("lazy var viewModel = AppViewModel(platformServices: .live())"))
    }

    func testPlatformEffectsCompileOnlyIntoTheApp() throws {
        let sources: [SourceFile] = [.appPlatformServices, .protectionUserNotificationController, .protectionHapticFeedback]
        let app = try targetSourcePaths("LavaSec")
        for source in sources {
            XCTAssertTrue(app.contains(source.rawValue))
            for target in ["LavaSecTunnel", "LavaSecWidget", "LavaSecIntents"] {
                XCTAssertFalse(try targetSourcePaths(target).contains(source.rawValue))
            }
        }
    }
}
