import XCTest
@testable import LavaSecCore

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
}
