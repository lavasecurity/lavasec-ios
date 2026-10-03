import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// The asymmetry a user reported, made testable.
///
/// 2026-09-02: switching Extra → Balanced applied correctly, and Messenger still could not connect
/// for over two hours until the Guard was manually cycled. "Switching to Extra works but not the
/// other way around" is exactly right — nothing posts a path change when only the filter changes,
/// so apps holding long-lived connections never re-resolve.
final class FilterLooseningReapplyPolicyTests: XCTestCase {
    private func counts(
        block: Int, allow: Int = 0, guardrail: Int = 0
    ) -> FilterLooseningReapplyPolicy.RuleCounts {
        FilterLooseningReapplyPolicy.RuleCounts(
            blockRuleCount: block, allowRuleCount: allow, guardrailRuleCount: guardrail)
    }

    /// A descendant leaving the threat set becomes reachable beneath a retained suffix allow,
    /// even though the parent allowance count remains one before and after adoption.
    func testAGuardrailReleasingAnAllowlistedDomainIsALoosening() {
        let allow = DomainRuleSet(suffixDomains: ["example.com"])
        let before = FilterSnapshot(blockRules: DomainRuleSet(), allowRules: allow,
                                    nonAllowableThreatRules: DomainRuleSet(suffixDomains: ["evil.example.com"]))
        let after = FilterSnapshot(blockRules: DomainRuleSet(), allowRules: allow)
        XCTAssertEqual(before.decision(for: "evil.example.com").action, .block)
        XCTAssertEqual(after.decision(for: "evil.example.com").action, .allow)
        XCTAssertTrue(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: .init(snapshot: before), adopted: .init(snapshot: after)))
    }

    /// ALLOWLISTING A GUARDRAILED DOMAIN OPENS NOTHING, and must not post a device-wide path
    /// change. Guardrail rules are the subset of the allowlist a guardrail overrides, so both
    /// counts rise together and the domain stays blocked. Independent axes read this as a
    /// loosening twice over (review, PR #645).
    func testAllowlistingAGuardrailedDomainIsNotALoosening() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 121_803, allow: 10, guardrail: 4),
                adopted: counts(block: 121_803, allow: 11, guardrail: 5)),
            "both counts moved together; nothing became reachable")
    }

    /// ...and REMOVING one from the allowlist opens nothing either: both counts fall together and
    /// the domain stays blocked by the ordinary block rule. This is the direction an independent
    /// guardrail axis got wrong, since the guardrail count decreased.
    func testUnAllowlistingAGuardrailedDomainIsNotALoosening() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 121_803, allow: 11, guardrail: 5),
                adopted: counts(block: 121_803, allow: 10, guardrail: 4)),
            "a guardrail decrease that merely tracks an allowlist removal opened nothing")
    }

    /// The two remaining shapes are NOT netted against each other. A change that unblocks something
    /// has unblocked it whatever else it tightened — summing into one total cancels this out.
    func testALooseningOnOneAxisCountsEvenWhenAnotherTightens() {
        XCTAssertTrue(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 100, allow: 0),
                adopted: counts(block: 500, allow: 4)),
            "a net-total comparison would call this a tightening and post nothing")
    }

    /// THE REPORTED CASE, in its reported numbers: Extra → Balanced.
    func testFewerBlockRulesIsALoosening() {
        XCTAssertTrue(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 383_201), adopted: counts(block: 121_803)))
    }

    /// THE COMMONEST LOOSENING, and the one a block-count-only test would miss: allowlisting a
    /// domain adds an allow rule and leaves the block count untouched. A user who allowlists a
    /// site and watches it stay unreachable is the same complaint in a smaller package.
    func testMoreAllowRulesIsALooseningEvenWhenBlockRulesAreUnchanged() {
        XCTAssertTrue(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 121_803, allow: 4),
                adopted: counts(block: 121_803, allow: 5)))
    }

    /// TIGHTENING MUST NOT NUDGE. A newly blocked domain fails on its next lookup by itself, so a
    /// reapply here would disturb every app's connections on the device to buy nothing — and
    /// reapplying is not free, it re-posts the path to every process.
    func testMoreBlockRulesIsNotALoosening() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 121_803), adopted: counts(block: 383_201)))
    }

    /// Removing an allowlist entry is a tightening too.
    func testFewerAllowRulesIsNotALoosening() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 100, allow: 5), adopted: counts(block: 100, allow: 4)))
    }

    /// An unchanged ruleset is not a loosening. Reload happens for many reasons that do not change
    /// rules at all — a resolver change, a configuration re-read, a recovery reload — and each one
    /// posting a path change would make the nudge constant background noise.
    func testAnUnchangedRulesetIsNotALoosening() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 121_803, allow: 5), adopted: counts(block: 121_803, allow: 5)))
    }

    /// A SWITCH THAT LOOSENS AND TIGHTENS AT ONCE still nudges. Blocking 10 more domains while
    /// unblocking 200_000 is the Extra → Balanced shape; refusing to nudge because something also
    /// got stricter would strand the connections the loosening freed.
    func testALooseningCountsEvenWhenTheOtherAxisTightened() {
        XCTAssertTrue(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 383_201, allow: 20),
                adopted: counts(block: 121_803, allow: 10)))
    }

    /// THE FIRST ADOPTION OF A SESSION IS NEVER A LOOSENING. `startTunnel` has just installed
    /// settings, and there is no earlier ruleset for anything to have been unblocked relative to.
    /// Treating nil as "everything loosened" would post a redundant reapply on every launch.
    func testTheFirstAdoptionIsNotALoosening() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(previous: nil, adopted: counts(block: 0)))
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: nil, adopted: counts(block: 383_201, allow: 20)))
    }

    /// THE STATED BLIND SPOT, pinned so it is a decision rather than a surprise. An adoption that
    /// swaps one blocked domain for another leaves both counts identical and posts no nudge.
    /// Detecting it means diffing rule SETS, which needs two rulesets resident in the packet-tunnel
    /// process — INV-MEM-1's ~50 MB ceiling has no room for that.
    func testAnEqualSizedSwapIsNotDetected() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 500, allow: 3), adopted: counts(block: 500, allow: 3)),
            "counts cannot see a same-size swap; this is the accepted cost of not holding two "
                + "rulesets resident in the NE process")
    }

    /// AN INDEPENDENT ALLOW AND GUARDRAIL CHANGE IN ONE ADOPTION IS NOT DETECTED, and the reason
    /// the obvious fix does not exist is the point of this test.
    ///
    /// Allowlisting a non-guardrailed domain while a catalog refresh newly guardrails a different,
    /// already-allowlisted one raises both counts by one. The first domain became reachable, so this
    /// IS a loosening, and the effective count cannot see it (review, PR #645).
    ///
    /// Handling the ambiguity conservatively is the natural suggestion and does not work: the
    /// second assertion is the case the subtraction exists to suppress — allowlisting a domain that
    /// IS guardrailed, which opens nothing — and it produces the identical `(10, 2) → (11, 3)`.
    /// Counts cannot separate them, so nudging on one nudges on both.
    func testAnIndependentAllowAndGuardrailChangeIsNotDetected() {
        let before = counts(block: 100, allow: 10, guardrail: 2)

        // Adoption A — a REAL loosening: allowlist a non-guardrailed domain (+1 allow) while a
        // catalog refresh newly guardrails a different, already-allowlisted one (+1 guardrail).
        let afterRealLoosening = counts(block: 100, allow: 11, guardrail: 3)

        // Adoption B — NOT a loosening: allowlist a domain that is itself guardrailed, which moves
        // both counts together and opens nothing. This is the case the subtraction exists for.
        let afterNoChangeInReachability = counts(block: 100, allow: 11, guardrail: 3)

        // The collision, asserted directly: two different adoptions, one set of counts.
        XCTAssertEqual(
            afterRealLoosening, afterNoChangeInReachability,
            "if these ever differ, counts CAN separate the two cases and this policy should be "
                + "revisited")

        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(previous: before, adopted: afterRealLoosening),
            "documented limitation: the newly reachable domain is missed because the guardrail "
                + "increase cancels it in the effective count")
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: before, adopted: afterNoChangeInReachability),
            "and staying quiet here is correct — which is why no count-based rule can get both "
                + "right, and why treating the ambiguity conservatively is not a free fix")
    }

    /// THE BLIND SPOT IS WIDER THAN AN EQUAL-SIZED SWAP, and this pins the general shape so nobody
    /// reads the case above as the whole of it.
    ///
    /// Counts detect net SHRINKAGE, not REMOVAL. A catalog refresh that replaces 100 blocked rules
    /// with 200 different ones unblocks every one of the old domains while `blockRuleCount` rises,
    /// so the predicate says no loosening. A list swap is an ordinary catalog event, not a rare one
    /// — an earlier revision of the policy's own documentation called this family rare, which was
    /// wrong (review, PR #645).
    ///
    /// This asserts the limitation rather than a desired behaviour: it is here to fail loudly if
    /// someone later believes counts alone closed it. Closing it needs removal-aware evidence the
    /// compile can afford — a rolling hash or Bloom summary of the block set in the artifact header
    /// — not a different comparison over the same three integers.
    func testRemovalsMaskedByALargerAdditionAreNotDetected() {
        XCTAssertFalse(
            FilterLooseningReapplyPolicy.isLoosening(
                previous: counts(block: 100, allow: 0), adopted: counts(block: 200, allow: 0)),
            "every one of the 100 previous domains may have been replaced; a growing count cannot "
                + "prove the new set is a superset of the old one")
    }
}
