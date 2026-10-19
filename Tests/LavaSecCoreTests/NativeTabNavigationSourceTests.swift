import XCTest

/// The native root mounts the RN navigator; product tabs have one owner.
final class NativeTabNavigationSourceTests: XCTestCase {
    func testProductTabsAreOwnedByReactNative() throws {
        let root = try readSource(.rootView)
        let navigation = try readSource(.reactNativeReviewNavigation)
        XCTAssertFalse(root.contains("TabView(selection: guardedRootTabSelection)"))
        XCTAssertTrue(root.contains("LavaAppHost()"))
        XCTAssertTrue(navigation.contains("<Tabs.Screen name=\"GuardTab\""))
        XCTAssertTrue(navigation.contains("<Tabs.Screen name=\"SettingsTab\""))
    }
}
