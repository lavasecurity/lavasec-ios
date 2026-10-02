import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterSnapshotTests: XCTestCase {
    func testThreatGuardrailBeatsAllowedException() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com")

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "malware.example.com")

        var guardrailRules = DomainRuleSet()
        try guardrailRules.insert(domain: "malware.example.com")

        let snapshot = FilterSnapshot(
            blockRules: blockRules,
            allowRules: allowRules,
            nonAllowableThreatRules: guardrailRules
        )

        XCTAssertEqual(snapshot.decision(for: "malware.example.com").action, .block)
        XCTAssertEqual(snapshot.decision(for: "malware.example.com").reason, .threatGuardrail)
    }

    func testAllowlistBeatsBlocklist() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com")

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "ads.example.com")

        let snapshot = FilterSnapshot(blockRules: blockRules, allowRules: allowRules)

        XCTAssertEqual(snapshot.decision(for: "ads.example.com").action, .allow)
        XCTAssertEqual(snapshot.decision(for: "ads.example.com").reason, .localAllowlist)
    }

    func testDefaultAllowsUnknownDomain() throws {
        let snapshot = FilterSnapshot(blockRules: DomainRuleSet())

        XCTAssertEqual(snapshot.decision(for: "apple.com"), .defaultAllow)
    }

    func testDecisionForNormalizedDomainUsesRuleOrdering() throws {
        var blockRules = DomainRuleSet()
        var allowRules = DomainRuleSet()
        var guardrailRules = DomainRuleSet()

        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try allowRules.insert(domain: "trusted.ads.example.com", matchesSubdomains: true)
        try guardrailRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        let snapshot = FilterSnapshot(
            blockRules: blockRules,
            allowRules: allowRules,
            nonAllowableThreatRules: guardrailRules
        )

        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "cdn.ads.example.com").reason, .blocklist)
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "trusted.ads.example.com").reason, .localAllowlist)
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "danger.example.com").reason, .threatGuardrail)
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "apple.com").reason, .defaultAllow)
    }

    func testConfigurationManualBlockedDomainsBlockByDefault() {
        let configuration = AppConfiguration(blockedDomains: ["casino.example"])
        let snapshot = configuration.filterSnapshot()

        XCTAssertEqual(snapshot.decision(for: "casino.example").action, .block)
        XCTAssertEqual(snapshot.decision(for: "casino.example").reason, .blocklist)
    }

    func testConfigurationCanSelectDoHResolverPreset() {
        let configuration = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoH.id)

        XCTAssertEqual(configuration.resolverPreset, .cloudflareDoH)
        XCTAssertEqual(configuration.filterSnapshot().resolver, .cloudflareDoH)
    }

    func testAllowlistStillBeatsManualBlockedDomainWhenNoGuardrailMatches() {
        let configuration = AppConfiguration(
            allowedDomains: ["school.example"],
            blockedDomains: ["school.example"]
        )
        let snapshot = configuration.filterSnapshot()

        XCTAssertEqual(snapshot.decision(for: "school.example").action, .allow)
        XCTAssertEqual(snapshot.decision(for: "school.example").reason, .localAllowlist)
    }

    func testConfigurationThreatGuardrailsOverrideAllowedExceptions() throws {
        var threatRules = DomainRuleSet()
        try threatRules.insert(domain: "danger.example")
        try threatRules.insert(domain: "unlisted-danger.example")

        let configuration = AppConfiguration(allowedDomains: ["danger.example", "school.example"])
        let snapshot = configuration.filterSnapshot(nonAllowableThreatRules: threatRules)

        XCTAssertEqual(snapshot.decision(for: "danger.example").reason, .threatGuardrail)
        XCTAssertEqual(snapshot.decision(for: "school.example").reason, .localAllowlist)
        XCTAssertEqual(snapshot.decision(for: "unlisted-danger.example").reason, .defaultAllow)
    }
    func testAllowedParentPreservesExactAndSuffixDescendantThreats() throws {
        let threats = DomainRuleSet(exactDomains: ["exact.example.com"], suffixDomains: ["malware.example.com"])
        let config = AppConfiguration(allowedDomains: ["example.com"])
        let snapshot = config.filterSnapshot(nonAllowableThreatRules: threats)
        XCTAssertEqual(snapshot.decision(for: "safe.example.com").reason, .localAllowlist)
        XCTAssertEqual(snapshot.decision(for: "exact.example.com").reason, .threatGuardrail)
        XCTAssertEqual(snapshot.decision(for: "child.exact.example.com").reason, .localAllowlist)
        XCTAssertEqual(snapshot.decision(for: "child.malware.example.com").reason, .threatGuardrail)
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "safe.example.com", reachableAliasDomains: ["malware.example.com"]).reason, .threatGuardrail)
    }

    func testThreatOverlapCoversAllowedDescendantsWithoutUnrelatedRules() throws {
        let threats = DomainRuleSet(
            exactDomains: ["exact.allowed.example", "unrelated.example"],
            suffixDomains: ["example.com", "malware.allowed.example", "other.example"]
        )
        let config = AppConfiguration(allowedDomains: ["allowed.example", "school.example.com"])
        let overlap = config.nonAllowableRulesForAllowedDomains(from: threats)

        XCTAssertEqual(overlap.count, 3)
        XCTAssertTrue(overlap.contains("exact.allowed.example"))
        XCTAssertTrue(overlap.contains("child.malware.allowed.example"))
        XCTAssertTrue(overlap.contains("child.school.example.com"))
        XCTAssertFalse(overlap.contains("unrelated.example"))
        XCTAssertFalse(overlap.contains("other.example"))
        XCTAssertFalse(overlap.contains("other.example.com"))
    }

}
