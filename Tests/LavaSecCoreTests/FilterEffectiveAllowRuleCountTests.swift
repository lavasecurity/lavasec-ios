import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

final class FilterEffectiveAllowRuleCountTests: XCTestCase {
    private func counts(_ snapshot: any FilterRuntimeSnapshot) -> FilterLooseningReapplyPolicy.RuleCounts {
        FilterLooseningReapplyPolicy.RuleCounts(snapshot: snapshot)
    }

    func testPartialThreatScopesPreserveParentAllowAcrossRegularAndCompactSnapshots() throws {
        let configuration = AppConfiguration(enabledBlocklistIDs: [], allowedDomains: ["example.com"])
        let cases: [(DomainRuleSet, Int)] = [
            (DomainRuleSet(exactDomains: ["evil.example.com", "bad.example.com"]), 1),
            (DomainRuleSet(suffixDomains: ["evil.example.com", "bad.example.com"]), 1),
            (DomainRuleSet(exactDomains: ["example.com"]), 1),
            (DomainRuleSet(suffixDomains: ["example.com"]), 0),
            (DomainRuleSet(suffixDomains: ["com"]), 0),
            (DomainRuleSet(exactDomains: ["example.com"], suffixDomains: ["example.com"]), 0)
        ]
        for (threats, expected) in cases {
            let regular = configuration.filterSnapshot(nonAllowableThreatRules: threats)
            let compact = CompactFilterSnapshot(preparedSnapshot: PreparedFilterSnapshot(
                identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
                snapshot: regular))
            let encoded = try compact.encodedData()
            let decoded = try CompactFilterSnapshot.decode(from: encoded)
            let summary = try CompactFilterSnapshot.readSummary(from: encoded)
            XCTAssertEqual(summary.guardrailRuleCount, regular.guardrailRuleCount,
                           "Raw threat-table cardinality remains the artifact integrity count")
            for snapshot: any FilterRuntimeSnapshot in [regular, compact, decoded] {
                XCTAssertEqual(counts(snapshot).effectiveAllowRuleCount, expected)
                XCTAssertEqual(snapshot.guardrailRuleCount, regular.guardrailRuleCount)
                XCTAssertEqual(FilterLooseningReapplyPolicy.isLoosening(
                    previous: counts(FilterSnapshot(blockRules: DomainRuleSet())),
                    adopted: counts(snapshot)), expected == 1)
                XCTAssertEqual(snapshot.decision(for: "safe.example.com"), regular.decision(for: "safe.example.com"))
                XCTAssertEqual(snapshot.decision(for: "evil.example.com"), regular.decision(for: "evil.example.com"))
            }
        }
    }

    func testFailClosedHasNoEffectiveAllowance() {
        XCTAssertEqual(counts(FailClosedRuntimeSnapshot(resolver: .google)).effectiveAllowRuleCount, 0)
        XCTAssertEqual(counts(FailClosedRuntimeSnapshot(resolver: .google)).allowedSuffixGuardrailCoverage, [:])
    }

    private func runtimeVariants(allow: DomainRuleSet, threats: DomainRuleSet) throws -> [any FilterRuntimeSnapshot] {
        let regular = FilterSnapshot(blockRules: DomainRuleSet(suffixDomains: ["example.com", "other.test"]),
                                     allowRules: allow, nonAllowableThreatRules: threats)
        let compact = CompactFilterSnapshot(preparedSnapshot: PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: AppConfiguration(enabledBlocklistIDs: []), catalog: nil),
            snapshot: regular))
        return [regular, compact, try CompactFilterSnapshot.decode(from: compact.encodedData())]
    }

    func testRemovingPartialGuardrailsNudgesAcrossRuntimeRepresentations() throws {
        let allow = DomainRuleSet(suffixDomains: ["example.com", "other.test"])
        let cases: [(String, DomainRuleSet, DomainRuleSet)] = [
            ("evil.example.com", DomainRuleSet(suffixDomains: ["evil.example.com"]), DomainRuleSet()),
            ("evil.example.com", DomainRuleSet(exactDomains: ["evil.example.com"]), DomainRuleSet()),
            ("example.com", DomainRuleSet(exactDomains: ["example.com"]), DomainRuleSet()),
            ("evil.example.com", DomainRuleSet(suffixDomains: ["evil.example.com", "bad.example.com"]),
             DomainRuleSet(suffixDomains: ["bad.example.com"])),
            ("evil.example.com", DomainRuleSet(suffixDomains: ["evil.example.com"]),
             DomainRuleSet(suffixDomains: ["bad.other.test"])),
            ("c.evil.example.com", DomainRuleSet(suffixDomains: ["evil.example.com"]),
             DomainRuleSet(suffixDomains: ["a.evil.example.com", "b.evil.example.com"]))
        ]
        for (released, beforeThreats, afterThreats) in cases {
            let before = try runtimeVariants(allow: allow, threats: beforeThreats)
            let after = try runtimeVariants(allow: allow, threats: afterThreats)
            for (previous, adopted) in zip(before, after) {
                XCTAssertEqual(previous.decision(for: released).reason, .threatGuardrail)
                XCTAssertEqual(adopted.decision(for: released).reason, .localAllowlist)
                XCTAssertEqual(previous.effectiveAllowRuleCount, adopted.effectiveAllowRuleCount)
                XCTAssertEqual(previous.blockRuleCount, adopted.blockRuleCount)
                XCTAssertTrue(FilterLooseningReapplyPolicy.isLoosening(
                    previous: counts(previous), adopted: counts(adopted)), released)
            }
        }
    }

    func testTighteningAndRedundantGuardrailRemovalDoNotNudge() throws {
        let allow = DomainRuleSet(suffixDomains: ["example.com"])
        let cases: [(DomainRuleSet, DomainRuleSet, DomainRuleSet)] = [
            (DomainRuleSet(), DomainRuleSet(suffixDomains: ["evil.example.com"]), allow),
            (DomainRuleSet(suffixDomains: ["evil.example.com"]), DomainRuleSet(), DomainRuleSet()),
            (DomainRuleSet(suffixDomains: ["unrelated.test"]), DomainRuleSet(), allow),
            (DomainRuleSet(exactDomains: ["evil.example.com"], suffixDomains: ["evil.example.com"]),
             DomainRuleSet(suffixDomains: ["evil.example.com"]), allow),
            (DomainRuleSet(suffixDomains: ["evil.example.com", "nested.evil.example.com"]),
             DomainRuleSet(suffixDomains: ["evil.example.com"]), allow)
        ]
        for (beforeThreats, afterThreats, afterAllow) in cases {
            let before = try runtimeVariants(allow: allow, threats: beforeThreats)
            let after = try runtimeVariants(allow: afterAllow, threats: afterThreats)
            for (previous, adopted) in zip(before, after) {
                XCTAssertFalse(FilterLooseningReapplyPolicy.isLoosening(
                    previous: counts(previous), adopted: counts(adopted)))
            }
        }
    }

    func testCoverageSummaryRetainsOnlyAllowKeysAndIgnoresRedundantThreatScopes() throws {
        let allow = DomainRuleSet(suffixDomains: ["example.com", "nested.example.com", "covered.test"])
        let threats = DomainRuleSet(
            exactDomains: ["host.nested.example.com", "evil.example.com"],
            suffixDomains: ["evil.example.com", "child.evil.example.com", "covered.test", "unrelated.test"])
        var parentCoverage = GuardrailScopeCoverage()
        parentCoverage.record(depth: 1, matchesSubdomains: true)
        parentCoverage.record(depth: 2, matchesSubdomains: false)
        var nestedCoverage = GuardrailScopeCoverage()
        nestedCoverage.record(depth: 1, matchesSubdomains: false)
        for snapshot in try runtimeVariants(allow: allow, threats: threats) {
            XCTAssertEqual(counts(snapshot).allowedSuffixGuardrailCoverage,
                           ["example.com": parentCoverage, "nested.example.com": nestedCoverage])
            XCTAssertEqual(snapshot.guardrailRuleCount, 6, "Artifact integrity still uses raw table cardinality")
        }
    }

    func testCoalescingThreatChildrenIntoAnEnclosingScopeDoesNotNudge() throws {
        let allow = DomainRuleSet(suffixDomains: ["example.com"])
        let cases: [(DomainRuleSet, DomainRuleSet)] = [
            (DomainRuleSet(exactDomains: ["a.evil.example.com", "b.evil.example.com"]),
             DomainRuleSet(suffixDomains: ["evil.example.com"])),
            (DomainRuleSet(suffixDomains: ["a.evil.example.com", "b.evil.example.com"]),
             DomainRuleSet(suffixDomains: ["evil.example.com"])),
            (DomainRuleSet(exactDomains: ["shallow.example.com", "a.evil.example.com", "b.evil.example.com"]),
             DomainRuleSet(exactDomains: ["shallow.example.com"], suffixDomains: ["evil.example.com"])),
            (DomainRuleSet(exactDomains: ["a.evil.example.com", "b.evil.example.com", "evil.example.com"]),
             DomainRuleSet(suffixDomains: ["evil.example.com"]))
        ]
        for (beforeThreats, afterThreats) in cases {
            let before = try runtimeVariants(allow: allow, threats: beforeThreats)
            let after = try runtimeVariants(allow: allow, threats: afterThreats)
            for (previous, adopted) in zip(before, after) {
                for retained in ["a.evil.example.com", "b.evil.example.com"] {
                    XCTAssertEqual(previous.decision(for: retained).action, .block)
                    XCTAssertEqual(adopted.decision(for: retained).action, .block)
                }
                XCTAssertEqual(previous.effectiveAllowRuleCount, adopted.effectiveAllowRuleCount)
                XCTAssertFalse(FilterLooseningReapplyPolicy.isLoosening(
                    previous: counts(previous), adopted: counts(adopted)))
            }
        }
    }

    func testExactAllowScopesRespectExactAndCoveringSuffixThreats() throws {
        let allow = DomainRuleSet(exactDomains: ["probe.example.com"])
        let cases: [(DomainRuleSet, Int)] = [
            (DomainRuleSet(exactDomains: ["probe.example.com"]), 0),
            (DomainRuleSet(suffixDomains: ["example.com"]), 0),
            (DomainRuleSet(exactDomains: ["example.com", "evil.probe.example.com"]), 1)
        ]
        let configuration = AppConfiguration(enabledBlocklistIDs: [])
        for (threats, expected) in cases {
            let regular = FilterSnapshot(blockRules: DomainRuleSet(), allowRules: allow,
                                         nonAllowableThreatRules: threats)
            let compact = CompactFilterSnapshot(preparedSnapshot: PreparedFilterSnapshot(
                identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
                snapshot: regular))
            XCTAssertEqual(counts(regular).effectiveAllowRuleCount, expected)
            XCTAssertEqual(counts(try CompactFilterSnapshot.decode(from: compact.encodedData())).effectiveAllowRuleCount, expected)
        }
    }
}
