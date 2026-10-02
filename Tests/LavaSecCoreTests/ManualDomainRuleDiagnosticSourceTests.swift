import XCTest
@testable import LavaSecCore

/// Pins the tunnel-side wiring of the user-manual-rule diagnostic. The decision logic itself is
/// executable (`ManualDomainRuleMatchTests`); this file guards the provider-side facts the
/// compiler cannot: that a fail-closed decision cannot reach the dedup slot, that the normalized
/// rule snapshot and the session dedup set are published and read through ONE lock-guarded state,
/// that the cap short-circuits before any rule scan or dedup hop, and that the dedup mutation is
/// serialized (no torn read, no per-query queue hop).
final class ManualDomainRuleDiagnosticSourceTests: XCTestCase {
    func testFailClosedDecisionCannotLogAManualRuleMatch() throws {
        let source = try readSource(.packetTunnelProviderDiagnostics)
        let helper = try sourceBlock(
            in: source,
            startingAt: "func recordManualRuleDecisionIfNeeded",
            endingBefore: "func markLocalProtectionUptimeStarted"
        )
        // The slot is inserted only AFTER the pure matcher returns a rule kind, and that matcher
        // returns nil for `.protectionUnavailable`; so a fail-closed block can neither log a
        // manual-rule match nor consume a pair's once-per-session slot.
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "ManualDomainRuleMatch.coverage",
                    "loggedKeys.insert",
                ],
                in: helper
            ),
            "the manual-rule diagnostic must route through the pure coverage matcher before it spends a dedup slot"
        )
    }

    func testTheManualRuleSnapshotIsPublishedUnderTheGuardedState() throws {
        let source = try readSource(.packetTunnelProviderConfiguration)
        let adoption = try sourceBlock(
            in: source,
            startingAt: "func adoptAppConfiguration",
            endingBefore: "static func tunnelNetworkKind"
        )
        XCTAssertTrue(
            adoption.contains("ManualDomainRuleSnapshot("),
            "the rule snapshot must be rebuilt when a new configuration is adopted"
        )
        XCTAssertTrue(
            adoption.contains("blocked: ManualDomainRuleSet(rawRules: configuration.blockedDomains)"),
            "the snapshot's blocked set must be normalized at adoption"
        )
        XCTAssertTrue(
            adoption.contains("allowed: ManualDomainRuleSet(rawRules: configuration.allowedDomains)"),
            "the snapshot's allowed set must be normalized at adoption"
        )
        XCTAssertTrue(
            adoption.contains("manualRuleDiagnosticState.withLock { $0.snapshot = snapshot }"),
            "adoption must publish the snapshot through the lock-guarded state, not a bare store"
        )

        // Exactly one snapshot write site across the whole class: the adoption above. A second
        // assignment would reintroduce a writer the off-queue read could tear against, and no
        // read-only pin could prove the single-writer contract.
        let provider = try readPacketTunnelProviderSource()
        XCTAssertEqual(
            sourceOccurrenceCount(of: "$0.snapshot =", in: provider),
            1,
            "the snapshot must have exactly one publication site — configuration adoption"
        )
        XCTAssertTrue(
            provider.contains("let manualRuleDiagnosticState = OSAllocatedUnfairLock("),
            "the state must be guarded by the repo's lock primitive, holding both snapshot and dedup set"
        )
    }

    func testTheOffQueueReadPathReadsTheGuardedState() throws {
        let source = try readSource(.packetTunnelProviderDiagnostics)
        let helper = try sourceBlock(
            in: source,
            startingAt: "func recordManualRuleDecisionIfNeeded",
            endingBefore: "func markLocalProtectionUptimeStarted"
        )
        let helperCode = sourceWithoutCommentLines(helper)
        XCTAssertTrue(
            helperCode.contains("manualRuleDiagnosticState.withLock"),
            "the off-queue diagnostic must read the lock-guarded state"
        )
        XCTAssertTrue(
            helperCode.contains("($0.snapshot, $0.loggedKeys.count)"),
            "the snapshot and the cap's count must come out of the SAME lock critical section"
        )
        XCTAssertFalse(
            helperCode.contains("manualRuleSnapshot")
                || helperCode.contains("manualRuleDecisionLoggedKeys"),
            "the off-queue read must not touch the pre-lock stored properties"
        )
        // The read is off-queue, before the once-per-match dedup+log hop.
        let coverageIndex = try XCTUnwrap(helperCode.range(of: "ManualDomainRuleMatch.coverage(")?.lowerBound)
        let hopIndex = try XCTUnwrap(helperCode.range(of: "dnsStateQueue.async")?.lowerBound)
        XCTAssertLessThan(
            coverageIndex, hopIndex,
            "coverage is computed off-queue before the serialized dedup hop"
        )
    }

    func testTheCoveredQueryShortCircuitsOnceEveryPairIsLogged() throws {
        let source = try readSource(.packetTunnelProviderDiagnostics)
        let helper = try sourceBlock(
            in: source,
            startingAt: "func recordManualRuleDecisionIfNeeded",
            endingBefore: "func markLocalProtectionUptimeStarted"
        )
        let helperCode = sourceWithoutCommentLines(helper)
        // The atomic count is read before the scan; the short-circuit return precedes any
        // `ManualDomainRuleMatch.coverage(...)` scan and any `dnsStateQueue.async` no-op hop.
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "guard loggedKeyCount < ManualDomainRuleMatch.loggedPairCount",
                    "ManualDomainRuleMatch.coverage(",
                    "dnsStateQueue.async",
                ],
                in: helperCode
            ),
            "the cap must short-circuit before scanning any rule or enqueuing a no-op dedup hop"
        )
    }

    func testTheDedupMutationIsSerializedUnderTheGuardedState() throws {
        let source = try readSource(.packetTunnelProviderDiagnostics)
        let helper = try sourceBlock(
            in: source,
            startingAt: "func recordManualRuleDecisionIfNeeded",
            endingBefore: "func markLocalProtectionUptimeStarted"
        )
        let helperCode = sourceWithoutCommentLines(helper)
        // Inside the once-per-match dnsStateQueue hop, the insert runs under the same lock the
        // reader takes; the cap is re-checked under the lock because the earlier read was a
        // snapshot, not a reservation.
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "dnsStateQueue.async",
                    "manualRuleDiagnosticState.withLock",
                    "state.loggedKeys.insert(key).inserted",
                ],
                in: helperCode
            ),
            "the dedup Set mutation must be serialized under the lock inside the dnsStateQueue hop"
        )
    }
}
