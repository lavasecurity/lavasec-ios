import XCTest
@testable import LavaSecCore

final class SubscriptionPolicyTests: XCTestCase {
    func testLavaSecurityPlusProductIDsMatchAppStoreConnectSetup() {
        XCTAssertEqual(LavaSecurityPlusPolicy.monthly.productID, "lava_security_plus_monthly")
        XCTAssertEqual(LavaSecurityPlusPolicy.yearly.productID, "lava_security_plus_yearly")
        XCTAssertEqual(
            LavaSecurityPlusPolicy.recommendedOfferOrder.map(\.productID),
            [
                "lava_security_plus_yearly",
                "lava_security_plus_monthly"
            ]
        )
    }

    func testLavaSecurityPlusPlansAreAutoRenewableSubscriptions() {
        XCTAssertTrue(LavaSecurityPlusPolicy.monthly.isSubscription)
        XCTAssertTrue(LavaSecurityPlusPolicy.yearly.isSubscription)
        XCTAssertEqual(LavaSecurityPlusPolicy.productIDs, [
            "lava_security_plus_monthly",
            "lava_security_plus_yearly"
        ])
    }

    func testPlusLimitsKeepPaidAliasForCompatibility() {
        XCTAssertEqual(FeatureLimits.plus, FeatureLimits.paid)
        XCTAssertEqual(AppConfiguration(isPaid: true).hasLavaSecurityPlus, true)
        XCTAssertEqual(AppConfiguration(isPaid: false).hasLavaSecurityPlus, false)
    }

    func testCustomDNSRequiresPaidPlan() {
        XCTAssertFalse(FeatureLimits.free.allowsCustomDNS)
        XCTAssertTrue(FeatureLimits.paid.allowsCustomDNS)
    }

    func testCustomBlocklistsRequirePaidPlan() {
        XCTAssertFalse(FeatureLimits.free.allowsCustomBlocklists)
        XCTAssertTrue(FeatureLimits.paid.allowsCustomBlocklists)
    }
}
