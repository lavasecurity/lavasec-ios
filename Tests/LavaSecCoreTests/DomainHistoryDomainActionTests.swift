import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DomainHistoryDomainActionTests: XCTestCase {
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
