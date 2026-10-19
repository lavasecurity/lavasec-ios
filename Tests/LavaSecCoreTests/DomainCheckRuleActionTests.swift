import XCTest
@testable import LavaSecKit

final class DomainCheckRuleActionTests: XCTestCase {
    private let validator = AllowlistValidator(nonAllowableThreatRules: DomainRuleSet())

    func testRemovingABlockedDomainNormalizesTheExactRuleAndPreservesOtherRules() throws {
        let original = AppConfiguration(allowedDomains: ["unrelated.com"],
                                        blockedDomains: ["example.com", "news.example.com", "other.com"])
        let changed = try original.applyingDomainCheckRuleAction(" News.Example.Com ", action: .removeBlockedDomain,
                                                               allowlistValidator: validator)
        XCTAssertEqual(changed.blockedDomains, ["example.com", "other.com"])
        XCTAssertEqual(changed.allowedDomains, original.allowedDomains)
        XCTAssertEqual(changed.filterSnapshot().decision(for: "news.example.com").action, .block)
        XCTAssertEqual(original.blockedDomains.count, 3)
    }

    func testRemovingABlockedDomainPreservesCoveringExceptionsAndDoesNotCreateOne() throws {
        for allowed: Set<String> in [[], ["example.com"]] {
            let original = AppConfiguration(allowedDomains: allowed, blockedDomains: ["news.example.com"])
            let changed = try original.applyingDomainCheckRuleAction("news.example.com", action: .removeBlockedDomain,
                                                                   allowlistValidator: validator)
            XCTAssertTrue(changed.blockedDomains.isEmpty)
            XCTAssertEqual(changed.allowedDomains, allowed)
            XCTAssertEqual(changed.filterSnapshot().decision(for: "news.example.com").action, .allow)
        }
    }

    func testRemovalTargetsEveryCoveringExceptionAndPreservesOtherRules() throws {
        let original = AppConfiguration(allowedDomains: ["example.com", "news.example.com", "other.com"],
                                        blockedDomains: ["example.com"])
        let changed = try original.applyingDomainCheckRuleAction(" WWW.News.Example.Com ", action: .removeAllowedException,
                                                               allowlistValidator: validator)
        XCTAssertEqual(try original.allowedExceptions(matching: "www.news.example.com"), ["example.com", "news.example.com"])
        XCTAssertEqual(changed.allowedDomains, ["other.com"])
        XCTAssertEqual(changed.blockedDomains, original.blockedDomains)
        XCTAssertEqual(changed.filterSnapshot().decision(for: "www.news.example.com").action, .block)
        XCTAssertEqual(original.allowedDomains.count, 3)
    }

    func testRemovingAnExceptionDoesNotCreateABlock() throws {
        let original = AppConfiguration(allowedDomains: ["example.com"])
        let changed = try original.applyingDomainCheckRuleAction("example.com", action: .removeAllowedException,
                                                               allowlistValidator: validator)
        XCTAssertTrue(changed.allowedDomains.isEmpty)
        XCTAssertTrue(changed.blockedDomains.isEmpty)
        XCTAssertEqual(changed.filterSnapshot().decision(for: "example.com").reason, .defaultAllow)
    }

    func testBlockRemovesCoveringExceptionsAndAddsOnlyTheCheckedDomain() throws {
        let original = AppConfiguration(allowedDomains: ["example.com", "news.example.com", "other.com"])
        let changed = try original.applyingDomainCheckRuleAction("www.news.example.com", action: .blocked,
                                                               allowlistValidator: validator)
        XCTAssertEqual(changed.allowedDomains, ["other.com"])
        XCTAssertEqual(changed.blockedDomains, ["www.news.example.com"])
        XCTAssertEqual(changed.filterSnapshot().decision(for: "www.news.example.com").action, .block)
        XCTAssertEqual(changed.filterSnapshot().decision(for: "sibling.example.com").action, .allow)
    }

    func testBlockCanRemoveAnOverrideWhenTheExactBlockAlreadyExistsAtCapacity() throws {
        let blocked = Set((0..<FeatureLimits.free.maxBlockedDomains).map { "blocked-\($0).example.com" })
        let original = AppConfiguration(allowedDomains: ["example.com"], blockedDomains: blocked)
        let changed = try original.applyingDomainCheckRuleAction("blocked-0.example.com", action: .blocked,
                                                               allowlistValidator: validator)
        XCTAssertEqual(changed.blockedDomains, blocked)
        XCTAssertTrue(changed.allowedDomains.isEmpty)
    }

    func testBlockCapacityFailureLeavesTheOriginalExceptionIntact() throws {
        let original = AppConfiguration(allowedDomains: ["example.com"], blockedDomains:
            Set((0..<FeatureLimits.free.maxBlockedDomains).map { "blocked-\($0).other.com" }))
        XCTAssertThrowsError(try original.applyingDomainCheckRuleAction("example.com", action: .blocked,
                                                                      allowlistValidator: validator))
        XCTAssertEqual(original.allowedDomains, ["example.com"])
    }

    func testBlockReusesACoveringParentAtCapacityAfterRemovingAnException() throws {
        var blocked = Set((0..<(FeatureLimits.free.maxBlockedDomains - 1)).map { "blocked-\($0).other.com" })
        blocked.insert("example.com")
        let original = AppConfiguration(allowedDomains: ["www.example.com", "unrelated.com"], blockedDomains: blocked)
        let changed = try original.applyingDomainCheckRuleAction("www.example.com", action: .blocked,
                                                               allowlistValidator: validator)
        XCTAssertEqual(changed.blockedDomains, blocked)
        XCTAssertEqual(changed.allowedDomains, ["unrelated.com"])
        XCTAssertEqual(changed.filterSnapshot().decision(for: "www.example.com").action, .block)
    }

    func testAnExplicitBlockStillAddsTheCheckedRuleWhenNoExceptionWasRemoved() throws {
        let original = AppConfiguration(blockedDomains: ["example.com"])
        let changed = try original.applyingDomainCheckRuleAction("www.example.com", action: .blocked,
                                                               allowlistValidator: validator)
        XCTAssertEqual(changed.blockedDomains, ["example.com", "www.example.com"])
    }

    func testMatchingRespectsLabelBoundariesAndAllowingRetainsThreatValidation() throws {
        let original = AppConfiguration(allowedDomains: ["example.com"])
        XCTAssertTrue(try original.allowedExceptions(matching: "notexample.com").isEmpty)
        var threats = DomainRuleSet()
        try threats.insert(domain: "danger.example")
        XCTAssertThrowsError(try original.applyingDomainCheckRuleAction("danger.example", action: .allowed,
            allowlistValidator: AllowlistValidator(nonAllowableThreatRules: threats)))
    }
}
