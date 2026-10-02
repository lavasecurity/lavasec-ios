import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

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

    func testDescendantThreatDoesNotEraseParentAllowedException() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "example.com", matchesSubdomains: true)
        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "example.com", matchesSubdomains: true)
        var threatRules = DomainRuleSet()
        try threatRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        XCTAssertEqual(blockRules.effectiveBlockedDomainRuleCount(
            allowRules: allowRules, nonAllowableThreatRules: threatRules), 0)
    }

    func testGuardedDescendantIsStillCountedBehindAllowedParent() throws {
        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "example.com")

        for matchesSubdomains in [false, true] {
            var blockRules = DomainRuleSet()
            try blockRules.insert(domain: "evil.example.com", matchesSubdomains: matchesSubdomains)
            var threatRules = DomainRuleSet()
            try threatRules.insert(domain: "evil.example.com", matchesSubdomains: matchesSubdomains)

            XCTAssertEqual(blockRules.effectiveBlockedDomainRuleCount(
                allowRules: allowRules, nonAllowableThreatRules: threatRules), 1)

            try blockRules.insert(domain: "safe.example.com", matchesSubdomains: true)
            XCTAssertEqual(blockRules.effectiveBlockedDomainRuleCount(
                allowRules: allowRules, nonAllowableThreatRules: threatRules), 1,
                "Only the unguarded child is released by the allowed parent")
        }
    }

    func testExactGuardrailAtAllowedParentDoesNotReleaseItsOnlyExactBlock() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "example.com", matchesSubdomains: false)
        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "example.com")
        var threatRules = DomainRuleSet()
        try threatRules.insert(domain: "example.com", matchesSubdomains: false)

        XCTAssertEqual(blockRules.effectiveBlockedDomainRuleCount(
            allowRules: allowRules, nonAllowableThreatRules: threatRules), 1)
    }

    func testRejectsIPAddresses() {
        XCTAssertThrowsError(try DomainName("1.1.1.1"))
        XCTAssertThrowsError(try DomainName("2001:4860:4860::8888"))
        XCTAssertThrowsError(try DomainName("999.999.999.999"))
    }

    func testNormalizesUnicodeDomainsToPunycode() throws {
        XCTAssertEqual(try DomainName("Bücher.Example").value, "xn--bcher-kva.example")
    }

    func testNormalizesTerminalDotsAndPunycodeTopLevelDomains() throws {
        XCTAssertEqual(try DomainName(" Example.COM. ").value, "example.com")
        XCTAssertEqual(try DomainName("EXAMPLE.XN--P1AI").value, "example.xn--p1ai")
    }

    func testEnforcesDNSLabelAndHostnameLengthBoundaries() throws {
        let label = String(repeating: "a", count: 63)
        XCTAssertNoThrow(try DomainName("\(label).example"))
        XCTAssertThrowsError(try DomainName("a\(label).example"))
        let maxHostname = [label, label, label, String(repeating: "b", count: 61)].joined(separator: ".")
        XCTAssertEqual(maxHostname.utf8.count, 253)
        XCTAssertNoThrow(try DomainName(maxHostname))
        XCTAssertThrowsError(try DomainName(maxHostname + "b"))
    }
}
