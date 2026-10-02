import XCTest

@testable import LavaSecCore

/// WHEN the tunnel publishes what it latched for T1 fallback (`PacketTunnelProvider`).
///
/// Pinned rather than executed because the publication writes `health` under `dnsStateQueue`
/// inside the provider, which the SPM package does not compile. The DERIVED content has real
/// tests (`ChainedTunnelResolverSelectionTests.fallbackOutcomes`); what no type can enforce is
/// that publication happens early enough to be true.
///
/// Publication used to be a side effect of the per-query route derive alone, so on an idle device
/// nothing was published until resolver work first asked for a route. A user who opened settings
/// and switched Alternative DNS off before any lookup saw `.off` — while the session had already
/// latched the resolver and would still use it for later failures (Codex, PR #575). The window is
/// small and entirely real: settings is exactly where someone goes right after connecting.
final class ChainedFallbackPublicationSourceTests: XCTestCase {
    func testTheLatchIsPublishedWhenTheRuntimeStarts() throws {
        let start = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "dnsStateQueue.sync {\n            chainedRuntime = runtime",
            endingBefore: "LavaSecDeviceDebugLog.append(component: \"tunnel\", event: \"chained-runtime-built\"")
        XCTAssertTrue(
            start.contains("publishChainedFallbackOutcomesOnQueue("),
            "the latch must be published when the session starts, not on the first resolution")
    }

    func testBothPublishersAreTheSameCode() throws {
        // The derive still republishes — a construction downgrade rewrites the latch WITHIN a
        // lifecycle, and the derive is where the new one is first seen. What must not happen is
        // two implementations: a start-time copy that drifts from the per-query one would report
        // one verdict on the settings screen and act on another.
        let source = try readPacketTunnelProviderSource()
        XCTAssertEqual(
            sourceOccurrenceCount(of: "health.chainedFallbackEvaluated = true", in: source), 1,
            "exactly one place may mark the fallback published — two would drift")
        // FOUR CALL SITES PLUS THE DECLARATION, and the count is deliberately exact so a fifth
        // site has to be argued for here rather than appearing quietly. The sites are: session
        // start (an idle device must not show a stale panel), the per-resolution route derive (a
        // construction downgrade rewrites the latch within a lifecycle), the T1 plan derive
        // (PR #592 — the route derive runs BEFORE the synchronous T0 attempt, so for a
        // device-DNS selection, whose addresses are a live capture, it can publish a set the rung
        // is no longer going to ask), and — arguing for the fourth as this comment requires —
        // the RELATCH on `reloadConfigurationMessage`.
        //
        // THE RELATCH SITE EARNS ITS CALL because it is the only one that replaces the latch
        // outside session start. The panel's `chainedFallbackLatchedIdentity` is what
        // `ChainedFallbackFreshness` compares against the user's current selection, so a relatch
        // that did not republish would leave the panel reporting `.awaitingRestart` about a
        // change already applied — the settings screen telling the user to restart protection for
        // work the tunnel had just done. The other three sites publish a latch they only READ;
        // this one publishes the latch it just WROTE, which is why it cannot be folded into them.
        //
        // This is a count of CALLS, not of implementations. The no-drift guarantee is the
        // assertion above: exactly one place marks the fallback published, so every site runs
        // the same code.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "publishChainedFallbackOutcomesOnQueue(", in: source), 5,
            "the one publisher, called from its declaration plus the start, route-derive, "
                + "rung-plan-derive and relatch sites")
    }

    func testThePublisherIsQueueConfinedAndChangeGated() throws {
        let publisher = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func publishChainedFallbackOutcomesOnQueue(",
            endingBefore: "func currentTunnelledPlainDNSRoute()")
        // INV-QUEUE-1: it writes `health`, which is dnsStateQueue-confined state.
        XCTAssertTrue(
            publisher.contains("dispatchPrecondition(condition: .onQueue(dnsStateQueue))"),
            "a health writer must assert its queue confinement")
        // The derive runs PER RESOLUTION. An unconditional write would mark health dirty on every
        // query and churn the debounced snapshot write for a value that moves once per latch.
        XCTAssertTrue(
            publisher.contains("guard !health.chainedFallbackEvaluated"),
            "publication must be change-gated so the per-query call costs a comparison")
    }

    /// The EFFECTIVE set names the addresses whose counters are moving.
    ///
    /// It used to be `selection.appendedFallback` — what the tunnelled ROUTE carries beyond
    /// T0. After PR #590 the route carries no T1 at all, so that list is empty for every
    /// physical-rung session, which is all of them. The snapshot field's contract is "the
    /// addresses the fallback counters aggregate", and those counters are now moving for exactly
    /// the admitted addresses — so publishing empty against moving counters silently broke the
    /// panel's attribution and the bug report's diagnostics (Codex, PR #590).
    func testTheEffectiveSetComesFromTheAdmittedOutcomes() throws {
        let publisher = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func publishChainedFallbackOutcomesOnQueue(",
            endingBefore: "/// Whether a physical path change leaves")
        XCTAssertTrue(
            publisher.contains(
                "let effective = outcomes.filter { $0.disposition == .admitted }.map(\\.address)"),
            "the effective set must be the admitted outcomes, which is what the counters aggregate")
        XCTAssertFalse(
            publisher.contains("selection.appendedFallback"),
            "the tunnel's append list no longer exists, let alone carries the effective set")
    }

    /// The freshness check compares an IDENTITY, and the publisher is what puts one in the
    /// snapshot for it to compare against.
    ///
    /// Endpoints alone cannot tell one transport of a provider from another when both reach the
    /// same host, so the panel reported "current" for a session running the other one and the
    /// user was never told a restart was needed (the plan's S4 obligation, "latch a
    /// transport-aware identity"). Only a pin can see that the provider publishes it.
    func testTheLatchedIdentityIsPublishedForTheFreshnessCheck() throws {
        let publisher = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func publishChainedFallbackOutcomesOnQueue(",
            endingBefore: "func currentTunnelledPlainDNSRoute()")
        XCTAssertTrue(
            publisher.contains("let identity = latch?.chainedTierOneResolverIdentity ?? \"\""),
            "the transport-aware identity must be published, not just the endpoints")
        XCTAssertTrue(
            publisher.contains("health.chainedFallbackLatchedIdentity = identity"),
            "...and written into the snapshot the app reads")
        // ONE LATCH READ for all of them, or a latch install between two reads puts two
        // selections in one snapshot.
        XCTAssertEqual(
            publisher.components(separatedBy: "latchedChainedTierOneResolverConfiguration").count - 1, 1,
            "the latch must be read exactly once for the whole publish")
    }

    /// A CHANGED EFFECTIVE SET clears the fallback evidence, because the evidence describes the
    /// addresses it was collected from.
    ///
    /// Free until PR #592: every selection's endpoints were fixed at latch, so the effective set
    /// could not move under a running session. A DEVICE-DNS selection is the one that can — its
    /// addresses are the tunnel's live capture — so a roam hands the rung a different resolver
    /// while the attempt, answer, rescue and streak totals keep accumulating, and the panel
    /// reports the new network's resolver as "Working" on the previous one's rescues
    /// (Codex P2, PR #592).
    ///
    /// Pinned rather than executable because the reset lives in the provider, and the shape that
    /// matters is WHICH counters are cleared and WHAT gates the clearing: without the
    /// `chainedFallbackEvaluated` gate the first publish of every session would read as a change
    /// and clear counters that belong to it.
    func testAChangedEffectiveSetResetsTheFallbackEvidence() throws {
        let publisher = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func publishChainedFallbackOutcomesOnQueue(",
            endingBefore: "func currentTunnelledPlainDNSRoute()")
        // ANCHORED ON THE `if` LINE, not on the whole condition. This test's subject is that the
        // reset is gated on a first publish and that a moved effective set is one of its terms; it
        // has no opinion about how many others sit beside it, and pinning them all made a correct
        // widening fail here twice.
        XCTAssertTrue(
            publisher.contains("if health.chainedFallbackEvaluated,"),
            "the reset is gated on a first publish, so an empty default is not read as a change")
        // SCOPED TO THE RESET'S OWN CONDITION, not to the whole publisher. Searched publisher-wide,
        // an assertion on the effective term passes even if it is deleted from the reset, because
        // the identical text appears in the publication change guard below — so the pin would go on
        // claiming to prevent the exact regression it had stopped detecting (Codex P2, PR #601).
        //
        // Delimited rather than matched as one literal: this asserts WHERE each term is without
        // dictating what else may sit beside it, which is the rule three CI failures in this file
        // paid for — specific about location, permissive about content.
        let resetKeyword = try XCTUnwrap(
            publisher.range(of: "if health.chainedFallbackEvaluated,"))
        let afterKeyword = publisher[resetKeyword.upperBound...]
        let conditionEnd = try XCTUnwrap(afterKeyword.range(of: "{"))
        let resetCondition = afterKeyword[..<conditionEnd.lowerBound]
        XCTAssertTrue(
            resetCondition.contains("health.chainedFallbackEffectiveAddresses != effective"),
            "a moved effective set must clear the evidence — asserted inside the reset condition, "
                + "since the change guard below carries the same comparison for another purpose")
        // THE SECOND TERM IS LOAD-BEARING, not belt-and-braces on the address term, and it is the
        // POLICY identity rather than the published resolver identity.
        //
        // Two selections can publish the same admitted addresses and still be different resolvers
        // — a DoH and a DoT preset on one hostname — so the address term alone lets the previous
        // resolver's counters describe the new one. That became reachable when PR #599 let the
        // reload handler relatch the rung under a running session.
        //
        // Then the same review found the resolver identity too narrow: the counters describe the
        // whole LADDER, so a change to `fallbackToDeviceDNS`, `usesEncryptedDeviceDNSFallback` or
        // the encrypted fallback preset relatches the rung and changes whether a T1 attempt
        // answers, while leaving the resolver identity and the effective set byte-identical
        // (Codex P2, PR #599).
        XCTAssertTrue(
            resetCondition.contains("policyChangedUnderIt"),
            "the whole ladder policy scopes the evidence, not just the resolver asked first")
        // The negative stays PUBLISHER-WIDE on purpose: the narrower spelling must not reappear
        // anywhere in this method, not merely outside the reset condition.
        XCTAssertFalse(
            publisher.contains("health.chainedFallbackLatchedIdentity != identity {"),
            "the published resolver identity is the panel's freshness input, not the evidence's")
        // AND THE SAME TERM GATES THE PUBLISH, scoped to that guard's own condition for the same
        // reason. A ladder-policy change moves neither the addresses nor the published identity, so
        // without this every other term of the change gate is false and the publisher returns
        // before health is marked dirty — clearing the resident counters while the persisted ones
        // the settings surface reads keep the old policy's numbers.
        let gateKeyword = try XCTUnwrap(
            publisher.range(of: "guard !health.chainedFallbackEvaluated"))
        let afterGate = publisher[gateKeyword.upperBound...]
        let gateEnd = try XCTUnwrap(afterGate.range(of: "else {"))
        XCTAssertTrue(
            afterGate[..<gateEnd.lowerBound].contains("policyChangedUnderIt"),
            "a reset that does not mark health dirty never reaches the settings surface")
        // STAMPED UNCONDITIONALLY, outside the reset — evidence from here on was gathered under
        // the current policy whether or not anything was cleared, and a stamp left inside would
        // make the next publish reset for a change already accounted for.
        let stamp = try XCTUnwrap(
            publisher.range(of: "publishedFallbackEvidencePolicyIdentity = policyIdentity"))
        let resetClose = try XCTUnwrap(
            publisher.range(of: "health.chainedFallbackUnhelpfulReplyStreak = 0"))
        XCTAssertLessThan(
            resetClose.lowerBound, stamp.lowerBound,
            "the stamp follows the reset block rather than sitting inside it")
        // ALL FIVE TERMS, and the enumeration is the assertion: the first cut of this reset
        // cleared four and left `chainedFallbackUnhelpfulReplyStreak` behind (Kilo, PR #592).
        // That one is the sharpest to miss — `ChainedFallbackStatus.status` reads it FIRST, so
        // at or above the threshold it returns `.answeringWithoutResolving` and no later branch
        // runs. A previous network's soft-failing resolver would have condemned the new one
        // outright, which is a louder wrong answer than the stale "Working" this block was
        // written for.
        for counter in [
            "health.chainedFallbackAttemptCount = 0",
            "health.chainedFallbackAnswerCount = 0",
            "health.chainedFallbackRescueCount = 0",
            "health.chainedFallbackUnansweredStreak = 0",
            "health.chainedFallbackUnhelpfulReplyStreak = 0"
        ] {
            XCTAssertTrue(
                publisher.contains(counter),
                "\(counter) describes the old address set and must be cleared with it")
        }
        // ORDERED BEFORE THE CHANGE GATE. Below the `guard` the reset would still run for this
        // case — a moved effective set is itself a change — but only incidentally, and the next
        // person to add a term to that guard could strand it.
        let reset = try XCTUnwrap(
            publisher.range(of: "health.chainedFallbackAttemptCount = 0"))
        let gate = try XCTUnwrap(publisher.range(of: "guard !health.chainedFallbackEvaluated"))
        XCTAssertLessThan(
            reset.lowerBound, gate.lowerBound,
            "the reset must not depend on the change gate's own terms to be reached")
    }

    /// Addresses the reset retires are RECORDED, so the redaction fold can still reach them.
    ///
    /// Clearing the counters is right — they described the old resolver — but the per-address maps
    /// (`resolverAttemptCounts` and siblings) are session-wide and keyed by whichever address was
    /// tried, so the retired resolver stays in them while this publish overwrites the lists the
    /// fold is built from. Without this the old address reaches a bug report as a verbatim key
    /// (Codex P1, PR #592). Executable coverage of the fold itself is
    /// `BugReportBundleTests.testTheReportCarriesNoRoamedAwayFallbackAddresses`; what only a pin
    /// can see is that the provider populates the field at the one moment the addresses are lost.
    func testRetiredAddressesStayFoldableForRedaction() throws {
        let publisher = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func publishChainedFallbackOutcomesOnQueue(",
            endingBefore: "func currentTunnelledPlainDNSRoute()")
        XCTAssertTrue(
            publisher.contains("health.chainedFallbackRetiredAddresses = retired"),
            "the addresses this reset drops must be recorded, or the fold loses them")
        // ALL THREE LISTS. They can differ — an `.alreadyPrimary` address is latched and never
        // effective, and it still keys the maps if it was tried — and the attempt keys are not a
        // spelling of either: an encrypted attempt is recorded under `doh:https://host/path` while
        // the latched list carries only the host, so a Custom DoH URL that changes its PATH moves
        // no address list at all while stranding the old full URL as a live map key. That reached
        // a report verbatim through the one list this block did not read (Codex P1, PR #592,
        // second round).
        XCTAssertTrue(
            publisher.contains("health.chainedFallbackEffectiveAddresses")
                && publisher.contains("+ health.chainedFallbackLatchedAddresses")
                && publisher.contains("+ health.chainedFallbackAttemptKeys"),
            "retire from all three lists, since any of them can key the counter maps")
        // AND THE EXCLUSION HAS TO WIDEN WITH IT, or every attempt key retires on every publish:
        // a key still named by the NEW attempt list is still folded by it.
        XCTAssertTrue(
            publisher.contains("!attemptKeys.contains(key)"),
            "a key the new list still names is still folded and must not be retired")
        // NOT NESTED IN THE RESET, and this is the assertion that matters most here. The two
        // blocks answer different questions off different lists: the reset asks whether the
        // EVIDENCE still describes what is being asked, which only the effective set can answer;
        // retiring asks whether an ADDRESS is leaving the snapshot while still keying the maps,
        // which the latched list answers on its own. A roam can replace an `.alreadyPrimary`
        // address — latched, never effective, keyed in the maps because T0 asks it — leaving
        // the admitted set untouched. Nested under the reset, that address was dropped unretired
        // and reached a report verbatim (Codex P1, second round).
        //
        // Asserted with ranges rather than a `containsInOrder` helper: that helper is declared
        // `private extension String` per test file, so reaching for it here would mean a third
        // copy of it. The range idiom is what this file already uses below.
        // Anchored on the reset's `if` LINE for the reason given on the test above: this assertion
        // is about the two blocks being SEPARATE and ordered, not about which terms the reset
        // carries. The trailing comma is what distinguishes it from the retire block's own
        // `if health.chainedFallbackEvaluated {`.
        let resetBlock = try XCTUnwrap(
            publisher.range(of: "if health.chainedFallbackEvaluated,"),
            "the reset keeps its own condition, whatever scopes the evidence that day")
        let retireBlock = try XCTUnwrap(
            publisher.range(of: "if health.chainedFallbackEvaluated {"),
            "retiring must be its own block, gated only on having published before — never on "
                + "the effective set having moved")
        XCTAssertLessThan(
            resetBlock.lowerBound, retireBlock.lowerBound,
            "the reset comes first; retiring is not nested inside it")
        let lastCounter = try XCTUnwrap(
            publisher.range(of: "health.chainedFallbackUnhelpfulReplyStreak = 0"))
        XCTAssertLessThan(
            lastCounter.lowerBound, retireBlock.lowerBound,
            "the counter clears belong to the reset block, above the retire block")
        // ...and it must retire only what is actually LEAVING, or the field stops meaning
        // "keys no list names any more" and starts meaning "every key ever published".
        //
        // `key`, not `address`: the loop widened to cover the attempt keys as well, and those are
        // not addresses. Keeping the old spelling here would have been a pin asserting a variable
        // NAME rather than the guarantee, which is what the exclusion below actually is.
        XCTAssertTrue(
            publisher.contains("!effective.contains(key) && !latched.contains(key)"),
            "a key still named by either address list is still folded by it")
        // Both blocks precede the change gate: below it they would be unreachable on the very
        // publishes that need them.
        let retire = try XCTUnwrap(
            publisher.range(of: "health.chainedFallbackRetiredAddresses = retired"))
        let gate = try XCTUnwrap(publisher.range(of: "guard !health.chainedFallbackEvaluated"))
        XCTAssertLessThan(retire.lowerBound, gate.lowerBound)
    }

    /// The redaction folds resolver counters by the keys ATTEMPTS are recorded under, and the
    /// publisher is what puts them in the snapshot.
    ///
    /// An encrypted attempt is recorded under the endpoint's `cacheIdentifier`
    /// (`doh:<absolute URL>`), not the host the panel displays — so folding on the host list
    /// matched nothing and a Custom DoH endpoint, path and query included, reached the bug report
    /// unredacted (Codex P1, PR #591). Only a pin can see that the provider publishes them.
    func testTheAttemptKeysArePublishedForTheRedaction() throws {
        let publisher = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func publishChainedFallbackOutcomesOnQueue(",
            endingBefore: "func currentTunnelledPlainDNSRoute()")
        XCTAssertTrue(
            publisher.contains("let attemptKeys = latch?.chainedTierOneResolverAttemptKeys ?? []"),
            "the counter keys must be published, not just the display endpoints")
        XCTAssertTrue(
            publisher.contains("health.chainedFallbackAttemptKeys = attemptKeys"),
            "...and written into the snapshot the redaction reads")
        XCTAssertTrue(
            publisher.contains("|| health.chainedFallbackAttemptKeys != attemptKeys"),
            "a change in them must republish, or the change gate holds a stale key set")
    }
}
