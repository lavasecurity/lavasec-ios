import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class TunnelConfigurationIdentityTests: XCTestCase {
    func testCurrentAndLegacyTunnelNamesMatchExpectedProvider() {
        XCTAssertTrue(
            LavaTunnelConfigurationIdentity.matches(
                displayName: "Lava Security",
                providerBundleIdentifier: "com.lavasec.app.tunnel",
                expectedProviderBundleIdentifier: "com.lavasec.app.tunnel"
            )
        )
        XCTAssertTrue(
            LavaTunnelConfigurationIdentity.matches(
                displayName: "Lava Sec",
                providerBundleIdentifier: "com.lavasec.app.tunnel",
                expectedProviderBundleIdentifier: "com.lavasec.app.tunnel"
            )
        )
    }

    func testTunnelIdentityRejectsWrongProviderOrDisplayName() {
        XCTAssertFalse(
            LavaTunnelConfigurationIdentity.matches(
                displayName: "Lava Security",
                providerBundleIdentifier: "com.example.other.tunnel",
                expectedProviderBundleIdentifier: "com.lavasec.app.tunnel"
            )
        )
        XCTAssertFalse(
            LavaTunnelConfigurationIdentity.matches(
                displayName: "Other VPN",
                providerBundleIdentifier: "com.lavasec.app.tunnel",
                expectedProviderBundleIdentifier: "com.lavasec.app.tunnel"
            )
        )
    }

    func testCurrentTunnelNameIsPreferredOverLegacyName() {
        XCTAssertLessThan(
            LavaTunnelConfigurationIdentity.displayNamePriority("Lava Security"),
            LavaTunnelConfigurationIdentity.displayNamePriority("Lava Sec")
        )
        XCTAssertLessThan(
            LavaTunnelConfigurationIdentity.displayNamePriority("Lava Sec"),
            LavaTunnelConfigurationIdentity.displayNamePriority("Other VPN")
        )
    }
}
