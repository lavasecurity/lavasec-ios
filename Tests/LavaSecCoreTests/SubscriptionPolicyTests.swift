import XCTest
@testable import LavaSecCore

final class SubscriptionPolicyTests: XCTestCase {
    func testLavaSecurityPlusProductIDsMatchAppStoreConnectSetup() {
        XCTAssertEqual(LavaSecurityPlusPolicy.monthly.productID, "lava_security_plus_monthly")
        XCTAssertEqual(LavaSecurityPlusPolicy.yearly.productID, "lava_security_plus_yearly")
        XCTAssertEqual(LavaSecurityPlusPolicy.yearlyPaidMonthly.productID, "lava_security_plus_yearly")
        XCTAssertEqual(
            LavaSecurityPlusPolicy.recommendedOfferOrder.map(\.id),
            [
                "yearly",
                "yearlyPaidMonthly",
                "monthly"
            ]
        )
        XCTAssertEqual(
            LavaSecurityPlusPolicy.paywallProductIDs,
            [
                "lava_security_plus_monthly",
                "lava_security_plus_yearly"
            ]
        )
    }

    func testLavaSecurityPlusPlansAreAutoRenewableSubscriptions() {
        XCTAssertTrue(LavaSecurityPlusPolicy.monthly.isSubscription)
        XCTAssertTrue(LavaSecurityPlusPolicy.yearly.isSubscription)
        XCTAssertTrue(LavaSecurityPlusPolicy.yearlyPaidMonthly.isSubscription)
    }

    func testLavaSecurityPlusOfferOrderKeepsYearlyCommitmentBetweenYearlyAndMonthly() {
        XCTAssertEqual(
            LavaSecurityPlusPolicy.recommendedOfferOrder.map(\.kind),
            [
                .yearly,
                .yearlyPaidMonthly,
                .monthly
            ]
        )
        XCTAssertEqual(
            LavaSecurityPlusPolicy.fallbackOfferOrder.map(\.kind),
            [
                .yearly,
                .monthly
            ]
        )
        XCTAssertFalse(LavaSecurityPlusPolicy.fallbackOfferOrder.contains { $0.kind == .yearlyPaidMonthly })
        XCTAssertEqual(LavaSecurityPlusPolicy.plan(for: "lava_security_plus_yearly")?.kind, .yearly)
        XCTAssertNotEqual(LavaSecurityPlusPolicy.plan(for: "lava_security_plus_yearly")?.kind, .yearlyPaidMonthly)
        XCTAssertNil(LavaSecurityPlusPolicy.plan(for: "lava_security_plus_lifetime"))
        XCTAssertEqual(
            LavaSecurityPlusPolicy.recommendedOfferOrder.map(\.id),
            [
                "yearly",
                "yearlyPaidMonthly",
                "monthly"
            ]
        )
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
