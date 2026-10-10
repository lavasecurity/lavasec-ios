import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DomainHistoryDomainActionTests: XCTestCase {
    func testAllowingAppleTrackerFromHistoryReversesItsManualBlock() throws {
        let validator = AllowlistValidator(nonAllowableThreatRules: DomainRuleSet())
        let blocked = try AppConfiguration().applyingDomainHistoryDomainAction(
            "gs-loc.apple.com", target: .blocked, allowlistValidator: validator
        ).configuration
        XCTAssertEqual(blocked.filterSnapshot().decision(for: "gs-loc.apple.com").action, .block)

        let allowed = try blocked.applyingDomainHistoryDomainAction(
            " GS-Loc.Apple.Com ", target: .allowed, allowlistValidator: validator
        ).configuration
        XCTAssertTrue(allowed.blockedDomains.isEmpty)
        XCTAssertEqual(allowed.allowedDomains, ["gs-loc.apple.com"])
        XCTAssertEqual(allowed.filterSnapshot().decision(for: "gs-loc.apple.com").reason, .localAllowlist)
    }

    func testHistoryStillRejectsAnExceptionForAnExplicitThreatRule() throws {
        var threats = DomainRuleSet()
        try threats.insert(domain: "danger.example")
        XCTAssertThrowsError(try AppConfiguration().applyingDomainHistoryDomainAction(
            "danger.example", target: .allowed,
            allowlistValidator: AllowlistValidator(nonAllowableThreatRules: threats)
        )) { error in
            XCTAssertEqual(error as? DomainHistoryDomainActionError,
                           .allowedDomainRejected(message: "Some dangerous domains cannot be allowed."))
        }
    }

    func testAddingBlockedDomainRemovesSameAllowedDomain() throws {
        let configuration = AppConfiguration(
            allowedDomains: ["tracker.example.com"],
            blockedDomains: ["ads.example.com"]
        )

        let result = try configuration.applyingDomainHistoryDomainAction(
            " Tracker.Example.Com ",
            target: .blocked,
            allowlistValidator: AllowlistValidator(nonAllowableThreatRules: DomainRuleSet())
        )

        XCTAssertEqual(result.normalizedDomain, "tracker.example.com")
        XCTAssertEqual(result.configuration.blockedDomains, ["ads.example.com", "tracker.example.com"])
        XCTAssertTrue(result.configuration.allowedDomains.isEmpty)
    }

    func testAddingAllowedDomainRemovesSameBlockedDomain() throws {
        let configuration = AppConfiguration(
            allowedDomains: ["school.example.com"],
            blockedDomains: ["news.example.com"]
        )

        let result = try configuration.applyingDomainHistoryDomainAction(
            "news.example.com",
            target: .allowed,
            allowlistValidator: AllowlistValidator(nonAllowableThreatRules: DomainRuleSet())
        )

        XCTAssertEqual(result.normalizedDomain, "news.example.com")
        XCTAssertEqual(result.configuration.allowedDomains, ["news.example.com", "school.example.com"])
        XCTAssertTrue(result.configuration.blockedDomains.isEmpty)
    }

    func testAddingBlockedDomainRejectsWhenBlockedLimitReached() throws {
        let configuration = AppConfiguration(
            blockedDomains: Set((0..<FeatureLimits.free.maxBlockedDomains).map { "blocked-\($0).example.com" })
        )

        XCTAssertThrowsError(
            try configuration.applyingDomainHistoryDomainAction(
                "new.example.com",
                target: .blocked,
                allowlistValidator: AllowlistValidator(nonAllowableThreatRules: DomainRuleSet())
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainHistoryDomainActionError,
                .blockedDomainLimitReached(limit: FeatureLimits.free.maxBlockedDomains)
            )
        }
    }

    func testAddingAllowedDomainRejectsWhenAllowedLimitReached() throws {
        let configuration = AppConfiguration(
            allowedDomains: Set((0..<FeatureLimits.free.maxAllowedDomains).map { "allowed-\($0).example.com" })
        )

        XCTAssertThrowsError(
            try configuration.applyingDomainHistoryDomainAction(
                "new.example.com",
                target: .allowed,
                allowlistValidator: AllowlistValidator(nonAllowableThreatRules: DomainRuleSet())
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainHistoryDomainActionError,
                .allowedDomainLimitReached(limit: FeatureLimits.free.maxAllowedDomains)
            )
        }
    }
}
