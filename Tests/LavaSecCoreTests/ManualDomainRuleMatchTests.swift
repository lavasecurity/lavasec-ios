import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ManualDomainRuleMatchTests: XCTestCase {
    func testExactAndSubdomainRulesMatch() {
        XCTAssertTrue(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "linkedin.com", by: ["linkedin.com"]))
        XCTAssertTrue(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "www.linkedin.com", by: ["linkedin.com"]))
        XCTAssertTrue(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "static.licdn.com", by: ["licdn.com"]))
    }

    func testSuffixCollisionDoesNotMatch() {
        // `notlinkedin.com` ends with `linkedin.com` byte-wise but is a different registrable
        // name; the leading dot in the rule's suffix test is what stops it.
        XCTAssertFalse(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "notlinkedin.com", by: ["linkedin.com"]))
        XCTAssertFalse(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "linkedin.com.evil.example", by: ["linkedin.com"]))
    }

    func testRulesAreNormalizedBeforeComparison() {
        XCTAssertTrue(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "www.linkedin.com", by: [" LinkedIn.com. "]))
    }

    func testUnnormalizableRuleIsSkippedNotFatal() {
        XCTAssertFalse(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "linkedin.com", by: ["1.2.3.4", "not a domain"]))
    }

    func testEmptyRuleSetNeverMatches() {
        XCTAssertFalse(ManualDomainRuleMatch.isCovered(
            normalizedDomain: "linkedin.com", by: [String]()))
    }

    func testFailClosedDecisionNeverProducesManualRuleCoverage() {
        // `.protectionUnavailable` blocks EVERY name without consulting the manual rules, so the
        // covered name here must not be attributed to a manual rule (and must not consume its dedup
        // slot). The provider-side consequence is pinned by
        // ManualDomainRuleDiagnosticSourceTests.testFailClosedDecisionCannotLogAManualRuleMatch.
        let blocked = ManualDomainRuleSet(rawRules: ["linkedin.com"])
        let allowed = ManualDomainRuleSet(rawRules: [String]())
        XCTAssertNil(ManualDomainRuleMatch.coverage(
            normalizedDomain: "linkedin.com",
            for: FilterDecision(action: .block, reason: .protectionUnavailable),
            blockedRules: blocked,
            allowedRules: allowed))
    }

    func testCoverageNamesTheMatchingRuleKind() {
        let blocked = ManualDomainRuleSet(rawRules: [" LinkedIn.com. "])
        let allowed = ManualDomainRuleSet(rawRules: ["example.com"])
        XCTAssertEqual(ManualDomainRuleMatch.coverage(
            normalizedDomain: "www.linkedin.com",
            for: FilterDecision(action: .block, reason: .blocklist),
            blockedRules: blocked,
            allowedRules: allowed), .block)
        XCTAssertEqual(ManualDomainRuleMatch.coverage(
            normalizedDomain: "example.com",
            for: FilterDecision(action: .allow, reason: .localAllowlist),
            blockedRules: blocked,
            allowedRules: allowed), .allow)
        XCTAssertNil(ManualDomainRuleMatch.coverage(
            normalizedDomain: "elsewhere.example",
            for: FilterDecision(action: .allow, reason: .defaultAllow),
            blockedRules: blocked,
            allowedRules: allowed))
    }

    func testNormalizedRuleSetKeepsExactAndSubdomainSemanticsAfterOneNormalization() {
        let rules = ManualDomainRuleSet(rawRules: [" LinkedIn.com. ", "1.2.3.4", "not a domain"])
        XCTAssertEqual(rules.normalizedRules, ["linkedin.com"])
        XCTAssertTrue(rules.covers(normalizedDomain: "linkedin.com"))
        XCTAssertTrue(rules.covers(normalizedDomain: "static.linkedin.com"))
        XCTAssertFalse(rules.covers(normalizedDomain: "notlinkedin.com"))
    }

    func testLoggedPairCountIsTwoRuleKindsTimesTwoActions() {
        XCTAssertEqual(ManualDomainRuleMatch.loggedPairCount, 4)
    }
}
