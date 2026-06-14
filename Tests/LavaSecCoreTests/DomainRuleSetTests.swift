import XCTest
@testable import LavaSecCore

final class DomainRuleSetTests: XCTestCase {
    func testSuffixRuleMatchesSubdomains() throws {
        var rules = DomainRuleSet()
        try rules.insert(domain: "ads.example.com", matchesSubdomains: true)

        XCTAssertTrue(rules.contains("ads.example.com"))
        XCTAssertTrue(rules.contains("cdn.ads.example.com"))
        XCTAssertFalse(rules.contains("example.com"))
    }

    func testExactRuleDoesNotMatchSubdomains() throws {
        var rules = DomainRuleSet()
        try rules.insert(domain: "login.example.com", matchesSubdomains: false)

        XCTAssertTrue(rules.contains("login.example.com"))
        XCTAssertFalse(rules.contains("cdn.login.example.com"))
    }

    func testContainsNormalizedSkipsRepeatedNormalization() throws {
        var rules = DomainRuleSet()
        try rules.insert(domain: "ads.example.com", matchesSubdomains: true)

        XCTAssertTrue(rules.containsNormalized("cdn.ads.example.com"))
        XCTAssertFalse(rules.containsNormalized("example.com"))
    }

    func testEffectiveBlockedDomainCountSubtractsAllowedOverlapsOnly() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "malware.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "manual.example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try allowRules.insert(domain: "school.example.com", matchesSubdomains: true)

        XCTAssertEqual(blockRules.effectiveBlockedDomainRuleCount(allowRules: allowRules), 2)
    }

    func testEffectiveBlockedDomainCountSubtractsOneConfiguredAllowedExceptionForCoveredRules() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "linkedin.com", matchesSubdomains: true)
        try blockRules.insert(domain: "www.linkedin.com", matchesSubdomains: true)
        try blockRules.insert(domain: "static.linkedin.com", matchesSubdomains: true)
        try blockRules.insert(domain: "manual.example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "linkedin.com", matchesSubdomains: true)

        XCTAssertEqual(blockRules.count, 4)
        XCTAssertEqual(blockRules.effectiveBlockedDomainRuleCount(allowRules: allowRules), 3)
    }

    func testEffectiveBlockedDomainCountDoesNotSubtractAllowedOverlapWhenGuardrailMatches() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        var guardrailRules = DomainRuleSet()
        try guardrailRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        XCTAssertEqual(
            blockRules.effectiveBlockedDomainRuleCount(
                allowRules: allowRules,
                nonAllowableThreatRules: guardrailRules
            ),
            1
        )
    }

    func testRejectsIPAddresses() {
        XCTAssertThrowsError(try DomainName("1.1.1.1"))
        XCTAssertThrowsError(try DomainName("2001:4860:4860::8888"))
        XCTAssertThrowsError(try DomainName("999.999.999.999"))
    }

    func testNormalizesUnicodeDomainsToPunycode() throws {
        XCTAssertEqual(try DomainName("Bücher.Example").value, "xn--bcher-kva.example")
    }
}
