import Foundation
import XCTest
import LavaSecAppServices

final class AppearancePreferencesServiceTests: XCTestCase {
    @MainActor
    func testNativeCommandPersistsAndRuntimeRecreationReadsAuthority() {
        let name = "AppearancePreferencesServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AppearancePreferencesService(defaults: defaults)
        XCTAssertEqual(service.snapshot.preference, .system)
        var events: [AppearancePreferencesSnapshot] = []
        let subscription = service.observe { events.append($0) }
        let accepted = service.setPreference(.dark)
        XCTAssertEqual(accepted.preference, .dark)
        XCTAssertEqual(accepted.revision, 1)
        XCTAssertEqual(defaults.string(forKey: "lavasec.customization.appearance"), "dark")
        XCTAssertEqual(events.map(\.preference), [.system, .dark])
        XCTAssertEqual(service.setPreference(.dark), accepted)
        XCTAssertEqual(events.count, 2, "Repeated commands do not create fictitious changes.")
        service.removeObserver(subscription)
        service.setPreference(.light)
        XCTAssertEqual(events.count, 2, "A disposed runtime stops receiving events.")
        let recreated = AppearancePreferencesService(defaults: defaults)
        XCTAssertEqual(recreated.snapshot.preference, .light)
    }

    @MainActor
    func testForegroundRefreshRepairsStaleSnapshotAndInvalidStoredValuesUseSystem() {
        let name = "AppearancePreferencesServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: "lavasec.customization.appearance")
        let service = AppearancePreferencesService(defaults: defaults)
        XCTAssertEqual(service.snapshot.preference, .dark)
        defaults.set("light", forKey: "lavasec.customization.appearance")
        XCTAssertEqual(service.refresh().preference, .light)
        defaults.set("unsupported", forKey: "lavasec.customization.appearance")
        XCTAssertEqual(service.refresh().preference, .system)
        XCTAssertNil(AppearancePreference(rawValue: "unsupported"))
    }
}
