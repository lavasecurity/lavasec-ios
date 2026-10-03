import XCTest

@testable import LavaSecCore

/// The tunnel wiring for the loosening nudge, which no executable test in this package can reach.
///
/// The behaviour is `FilterLooseningReapplyPolicy`'s and is tested there. What has to be pinned is
/// that the provider consults it at the right moment, on the right queue, and that the evidence
/// survives a bug report.
final class FilterLooseningReapplySourceTests: XCTestCase {
    /// A loosening adoption posts a path change, so apps holding long-lived connections re-resolve.
    ///
    /// 2026-09-02: Extra → Balanced applied correctly and Messenger could not connect for over two
    /// hours, until the Guard was cycled by hand. `reapplyTunnelNetworkSettings` was reached only
    /// on a RESOLVER change, so a filter-only change posted nothing.
    func testALooseningAdoptionNudgesConnectedApps() throws {
        let provider = try readPacketTunnelProviderSource()
        let nudge = try sourceBlock(
            in: provider,
            startingAt: "func recordAdoptedRuleCounts(",
            endingBefore: "func reapplyTunnelNetworkSettings(")

        XCTAssertTrue(
            nudge.contains("FilterLooseningReapplyPolicy.isLoosening("),
            "the decision belongs to the shared policy, not to a re-derivation in the provider")
        XCTAssertTrue(
            nudge.contains("reapplyTunnelNetworkSettings(reason: \"ruleset-loosened\""),
            "posting the path change IS the nudge — the whole point of the fix")
        XCTAssertTrue(
            nudge.contains("enforceThrottle: false"),
            "UNTHROTTLED, like the configuration-change caller. The flap caller's throttle DROPS on "
                + "contention, and a dropped nudge is the bug this path exists to fix; the deferral "
                + "machinery an earlier revision built instead cost far more than the redundant "
                + "posts it saved (review, PR #645)")

        // The previous counts must be stored on EVERY adoption, not only on a loosening — the next
        // comparison is against what was actually adopted, and skipping the write on a tightening
        // would compare a later loosening against a stale, larger baseline and miss it.
        let storeIndex = try XCTUnwrap(nudge.range(of: "lastAdoptedRuleCounts = adopted"))
        let guardIndex = try XCTUnwrap(nudge.range(of: "guard isLoosening else {"))
        XCTAssertLessThan(
            storeIndex.lowerBound, guardIndex.lowerBound,
            "the baseline is updated before the early return, or a tightening poisons the next "
                + "comparison")

        // AND NO SUPERSESSION GATE AT ALL. An earlier revision suppressed the nudge when a newer
        // reload had advanced the generation, which assumed a successor that always nudges — but a
        // successor taking `residentSnapshotSatisfiesReload`'s no-op path never reaches this method,
        // so the committed loosening stayed live with no path change ever posted (Codex, PR #645).
        // Running inside the commit's own ordering removes the window the gate was guarding.
        XCTAssertFalse(
            nudge.contains("guard self.isCurrentSnapshotReloadGeneration(generation) else {"),
            "the commit is already generation-gated; re-checking here suppresses a nudge whose "
                + "successor may never post one")
        XCTAssertTrue(
            nudge.contains("dispatchPrecondition(condition: .onQueue(dnsStateQueue))"),
            "caller-confined to the queue rather than hopping onto it: hopping AFTER the commit "
                + "released the queue is what let a descheduled task be overtaken and then "
                + "overwrite the baseline out of commit order")

        // EXITING FAIL-CLOSED IS ALWAYS A LOOSENING. A fail-closed resident blocks everything and
        // does not update the baseline, so recovery compares against the last HEALTHY ruleset —
        // and a recovery into a tighter filter than that one reads as a tightening and posts
        // nothing, leaving every app that failed during the window stuck (Codex, PR #645).
        XCTAssertTrue(
            nudge.contains("recoveringFromFailClosed"),
            "leaving fail-closed must nudge whatever the counts say")
    }

    /// The record happens at the COMMIT, not in the post-commit block that a newer reload skips.
    func testTheBaselineIsRecordedFromTheSnapshotCommit() throws {
        let provider = try readPacketTunnelProviderSource()
        let commit = try sourceBlock(
            in: provider,
            startingAt: "let didCommitRealSnapshot = self.replaceSnapshot(",
            endingBefore: "self.advanceFocusConfigurationWatermark(")

        XCTAssertTrue(
            commit.contains("onCommittedWhileHoldingQueue: { [self] replacedBlockAllResident in"),
            "the record is commit-ORDERED work, run inside replaceSnapshot's own dnsStateQueue "
                + "hold: reacquiring the queue after it returns is not ordered against it")
        XCTAssertTrue(
            commit.contains("recordAdoptedRuleCounts("),
            "and it is still the shared recorder, not a re-derivation at the call site")
        XCTAssertTrue(
            commit.contains("recoveringFromFailClosed: replacedBlockAllResident"),
            "read from the resident being REPLACED, not from a marker: three paths install a "
                + "block-all resident and each sets a different flag, so enumerating them at the "
                + "call site missed a different one on each of three rounds")
    }

    /// The baseline is per-session, and the provider instance is not.
    ///
    /// NetworkExtension reuses the provider across starts, so without an explicit clear a
    /// same-instance restart compares its first adoption against the previous session's ruleset —
    /// inventing a nudge at startup, or suppressing the first real one if the old session was
    /// looser.
    ///
    /// `FilterLooseningReapplyPolicy` documents `nil` as meaning there is no ruleset to have been
    /// loosened RELATIVE TO — a fact about the state, not about how early in the session it is — so the
    /// baseline has to be MADE true on both sides: reset per session here, and re-seeded whenever
    /// the bootstrap installs a real resident (`testStartupSeedsTheBaselineFromARealBootstrapResident`
    /// below). Reading it as "the first adoption of a session" is precisely what left the nudge
    /// inert on the fast-resume path, so this docstring must not restate that reading (review,
    /// PR #645).
    func testTheBaselineIsClearedForEachTunnelSession() throws {
        let provider = try readPacketTunnelProviderSource()
        let load = try sourceBlock(
            in: provider,
            startingAt: "func loadInitialSharedState() -> Bool {",
            endingBefore: "This restart ENDS the previous fail-closed window")

        XCTAssertTrue(
            load.contains("dnsStateQueue.sync { lastAdoptedRuleCounts = nil }"),
            "the loosening baseline belongs to the released session, like the resident beside it")
    }

    /// RESETTING THE BASELINE IS ONLY HALF; THE BOOTSTRAP HAS TO RE-SEED IT.
    ///
    /// The reset above is correct — the old counts belong to the released session — but leaving the
    /// baseline `nil` silently disabled this whole fix on the commonest cold start. A strict
    /// fast-resume installs the user's own on-disk artifact as a REAL resident and stamps its
    /// identity; `loadSnapshotInBackground` then takes `residentSnapshotSatisfiesReload`'s no-op
    /// path and returns before any commit, so `recordAdoptedRuleCounts` never runs. The first later
    /// Extra → Balanced or allowlist change then compared against `nil`, read as "first adoption of
    /// a session", and posted nothing — leaving the reported apps stuck (review, PR #645).
    ///
    /// The condition is `blocksEveryLookup`, not "is there an identity": a fail-closed bootstrap
    /// must stay `nil`, because recovery from it is a loosening whatever the counts say and the
    /// commit path detects that separately from the resident it replaces.
    func testStartupSeedsTheBaselineFromARealBootstrapResident() throws {
        let provider = try readPacketTunnelProviderSource()
        let load = try sourceBlock(
            in: provider,
            startingAt: "func loadInitialSharedState() -> Bool {",
            endingBefore: "cancelTransientBootstrapDNSWait(reason: \"loadInitialSharedState\")")

        XCTAssertTrue(
            load.contains("if !bootstrapSnapshot.blocksEveryLookup {"),
            "a real bootstrap resident is what a later adoption must be compared against; a "
                + "block-all one must stay nil so recovery from it counts as a loosening")
        XCTAssertTrue(
            load.contains("dnsStateQueue.sync { lastAdoptedRuleCounts = bootstrapCounts }"),
            "the seed is dnsStateQueue-confined like every other access to this state (INV-QUEUE-1)")

        // ORDER: seeded from the resident that was actually published, so the two cannot disagree.
        let publish = try XCTUnwrap(load.range(of: "snapshot = bootstrapSnapshot"))
        let seed = try XCTUnwrap(load.range(of: "if !bootstrapSnapshot.blocksEveryLookup {"))
        let reset = try XCTUnwrap(load.range(of: "dnsStateQueue.sync { lastAdoptedRuleCounts = nil }"))
        XCTAssertLessThan(
            reset.lowerBound, publish.lowerBound,
            "the previous session's counts are dropped before the new resident is installed")
        XCTAssertLessThan(
            publish.lowerBound, seed.lowerBound,
            "seeding before the publish would record counts for a resident that may not be the one "
                + "installed")
    }

    /// A SETTINGS POST NEEDS A LIVE SESSION, on the leading edge as well as the trailing one.
    ///
    /// The deferred branch checked the lifecycle from the start; the immediate one did not, and this
    /// PR is what made that asymmetry reachable. `stopTunnel` runs `invalidateTunnelLifecycle`
    /// SYNCHRONOUSLY, while the cleanup calling `invalidateSnapshotReloadGeneration` is dispatched
    /// with `dnsStateQueue.async` — so in the window between them the activity bit is false but the
    /// reload generation still passes. A decode finishing there commits, the commit closure records
    /// the counts, and a loosening whose one-second floor had elapsed posted
    /// `setTunnelNetworkSettings` into a provider being torn down. The two pre-existing callers are
    /// network/config events that cannot land in that window; the snapshot-commit caller added here
    /// is exactly the one that can (review, PR #645).
    func testASettingsPostIsFencedToALiveLifecycle() throws {
        let provider = try readPacketTunnelProviderSource()
        let reapply = try sourceBlock(
            in: provider,
            startingAt: "func reapplyTunnelNetworkSettings(",
            endingBefore: "    private func recordNetworkSettingsReapplyFailure(")

        XCTAssertTrue(
            reapply.contains("guard tunnelLifecycleIsActive else {"),
            "a commit landing during teardown must not write settings to a stopped provider")

        let fence = try XCTUnwrap(reapply.range(of: "guard tunnelLifecycleIsActive else {"))
        let post = try XCTUnwrap(reapply.range(of: "setTunnelNetworkSettings(settingsBundle.settings)"))
        XCTAssertLessThan(
            fence.lowerBound, post.lowerBound,
            "the fence has to precede the post it guards")
    }

    /// THE THROTTLE IS AN INTERVAL, SO IT NEEDS A CLOCK THAT ONLY GOES FORWARD.
    ///
    /// This guard is the network-flap caller's, and it predates this PR — but it measured its
    /// interval on the wall clock, so a backward correction turns `elapsed` negative, the `>=`
    /// fails, and every throttled post is dropped for the duration of the rollback (review,
    /// PR #645). `DispatchTime` cannot run backwards.
    ///
    /// The loosening caller does not reach this guard at all: it posts unthrottled, precisely so a
    /// drop can never swallow it.
    func testTheThrottleUsesAMonotonicClock() throws {
        let provider = try readPacketTunnelProviderSource()
        let reapply = try sourceBlock(
            in: provider,
            startingAt: "func reapplyTunnelNetworkSettings(",
            endingBefore: "    private func recordNetworkSettingsReapplyFailure(")

        XCTAssertTrue(
            reapply.contains("let now = DispatchTime.now()"),
            "an interval measured on the wall clock is not an interval")
        // `sourceCodeOnly` strips whole-line comments, which this assertion needs: the rationale in
        // this very block names the `Date`-based revision it replaced, and the raw slice would match
        // its own explanation. That is the exact failure the helper's own doc records.
        XCTAssertFalse(
            sourceCodeOnly(reapply).contains("Date()"),
            "no wall-clock reading may re-enter the throttle arithmetic")
        // And the operation specifically, which no prose here uses, so it needs no stripping.
        XCTAssertFalse(
            reapply.contains("timeIntervalSince("),
            "a wall-clock interval is what the monotonic reading replaced")
        XCTAssertTrue(
            reapply.contains("max(0, Double(now.uptimeNanoseconds)"),
            "clamped and computed in Double, so an out-of-order pair cannot trap on UInt64 "
                + "underflow inside the NE process")

        // The marker it compares against has to be the monotonic one too, or the clock only
        // changed on one side of the subtraction.
        let declaration = try sourceBlock(
            in: provider,
            startingAt: "var lastNetworkSettingsReapplyUptime: DispatchTime?",
            endingBefore: "static let networkSettingsReapplyMinimumInterval")
        XCTAssertFalse(
            declaration.contains("Date"),
            "a DispatchTime reading compared against a Date marker is the same defect with an "
                + "extra step")
    }

    /// A FAILED POST MUST NOT CONSUME THE NUDGE.
    ///
    /// `recordAdoptedRuleCounts` advances the baseline before posting, so a transient
    /// `setTunnelNetworkSettings` failure leaves the loosening accounted for with no path change
    /// having happened: an identical later reload compares equal, reads as no loosening, and posts
    /// nothing (review, PR #645).
    ///
    /// The retry re-posts rather than rewinding the baseline — the baseline records what is
    /// RESIDENT, and the resident genuinely changed; only the notification was lost.
    ///
    /// The bound is a plain parameter, which is sound only because this path no longer defers. An
    /// earlier revision carried it as a `-retry` suffix on the reason while a trailing timer
    /// rewrote that reason to `…-retry-deferred`, defeating the bound and posting settings once a
    /// second indefinitely. With the timer gone there is no hop for the flag to survive.
    func testAFailedPostIsRetriedOnce() throws {
        let provider = try readPacketTunnelProviderSource()
        let reapply = try sourceBlock(
            in: provider,
            startingAt: "func reapplyTunnelNetworkSettings(",
            endingBefore: "    private func recordNetworkSettingsReapplyFailure(")

        XCTAssertTrue(
            reapply.contains("guard !isRetryOfFailedPost else {"),
            "bounded to ONE attempt, or a persistently failing post becomes an endless series of "
                + "device-wide path changes")
        XCTAssertTrue(
            reapply.contains("self.tunnelLifecycleGeneration == postedForLifecycle"),
            "the retry belongs to the session that posted, not to whichever one is live when the "
                + "failure callback runs")
        XCTAssertTrue(
            reapply.contains("let postedForLifecycle = tunnelLifecycleGeneration"),
            "captured on the queue at post time, not read from inside the callback")
        XCTAssertTrue(
            reapply.contains("isRetryOfFailedPost: true"),
            "the retry marks itself, which is what makes the bound hold")

        // The bound must NOT live in the reason string: that is what the removed trailing timer
        // defeated by rewriting it.
        XCTAssertFalse(
            sourceCodeOnly(reapply).contains("hasSuffix"),
            "a bound carried in a decorated string is a bound other code can erase")
        // And the retry must not rewind the baseline.
        XCTAssertFalse(
            sourceCodeOnly(reapply).contains("lastAdoptedRuleCounts"),
            "the baseline describes the RESIDENT, which really did change")
    }

    /// Both adoption and cold bootstrap must capture the scope-aware runtime metric, not
    /// reconstruct it by subtracting raw threat cardinality from the parent allow count.
    func testTheAdoptedCountsComeFromTheCommittedSnapshot() throws {
        let provider = try readPacketTunnelProviderSource()
        let commit = try sourceBlock(
            in: provider,
            startingAt: "onCommittedWhileHoldingQueue: { [self] replacedBlockAllResident in",
            endingBefore: "// Adopted a full snapshot")
        XCTAssertTrue(commit.contains("recordAdoptedRuleCounts(\n                        adoptedRuleCounts,"))
        XCTAssertFalse(sourceCodeOnly(commit).contains("RuleCounts(snapshot:"))
        let preparation = try sourceBlock(in: provider, startingAt: "let runtimePolicySnapshot = ResolverAdjustedRuntimeSnapshot(",
                                          endingBefore: "// A real snapshot is now resident")
        let capture = try XCTUnwrap(preparation.range(of: "let adoptedRuleCounts = FilterLooseningReapplyPolicy.RuleCounts(snapshot: runtimeSnapshot)"))
        let queueEntry = try XCTUnwrap(preparation.range(of: "self.dnsStateQueue.sync"))
        XCTAssertLessThan(capture.lowerBound, queueEntry.lowerBound,
                          "Threat coverage must be computed outside the DNS state queue")
        XCTAssertTrue(provider.contains("FilterLooseningReapplyPolicy.RuleCounts(snapshot: bootstrapSnapshot)"))
        XCTAssertFalse(sourceCodeOnly(provider).contains("guardrailRuleCount: runtimeSnapshot.guardrailRuleCount"))
        XCTAssertFalse(sourceCodeOnly(provider).contains("guardrailRuleCount: bootstrapSnapshot.guardrailRuleCount"))
    }

    func testResolverWrapperForwardsTheEffectiveAllowanceCount() throws {
        let provider = try readPacketTunnelProviderSource()
        let wrapper = try sourceBlock(in: provider, startingAt: "struct ResolverAdjustedRuntimeSnapshot:",
                                      endingBefore: "class PacketTunnelProvider:")
        XCTAssertTrue(wrapper.contains("var effectiveAllowRuleCount: Int {"))
        XCTAssertTrue(wrapper.contains("base.effectiveAllowRuleCount"))
        XCTAssertTrue(wrapper.contains("var allowedSuffixGuardrailCoverage: [String: GuardrailScopeCoverage] {"))
        XCTAssertTrue(wrapper.contains("base.allowedSuffixGuardrailCoverage"))
    }

    /// EVERY ADOPTION IS COUNTED, not just the ones that nudge.
    ///
    /// The counter exists to answer the open question from PR #645 — whether to drop the policy and
    /// nudge on every adoption — which turns on how often a real device adopts at all. Neither
    /// existing event measures that: `ruleset-loosened-nudge` sits below the loosening gate and sees
    /// only that subset, and `loadSnapshot-loaded` is emitted without testing
    /// `didCommitRealSnapshot`, so it also counts reloads the generation gate rejected.
    ///
    /// So the placement is the whole contract. Moving the increment below the gate would silently
    /// turn a total into the nudge count and make the measurement answer the wrong question while
    /// still producing plausible numbers.
    func testEveryAdoptionIsCountedForQA() throws {
        let provider = try readPacketTunnelProviderSource()
        let record = try sourceBlock(
            in: provider,
            startingAt: "func recordAdoptedRuleCounts(",
            endingBefore: "func reapplyTunnelNetworkSettings(")

        let incrementIndex = try XCTUnwrap(record.range(of: "adoptedSnapshotCount += 1"))
        let gateIndex = try XCTUnwrap(record.range(of: "guard isLoosening else {"))
        XCTAssertLessThan(
            incrementIndex.lowerBound, gateIndex.lowerBound,
            "the counter must be incremented BEFORE the loosening gate, or it counts nudges rather "
                + "than adoptions and the rate it is meant to measure is silently wrong")

        XCTAssertTrue(
            record.contains("event: \"ruleset-adopted\""),
            "the count has to reach a bug report to be QA evidence at all")
        XCTAssertTrue(
            record.contains("\"loosened\": \"\\(isLoosening)\""),
            "one event carries both arms: the total, and how much of it the policy suppresses")
        // NAMED FOR THE VERDICT, NOT THE OUTCOME. A commit landing in the `stopTunnel` window gets
        // a true verdict and then skips the post on the lifecycle guard, so a field named `nudged`
        // would overstate nudges and bias the ratio this event exists to measure (Codex, PR #647).
        XCTAssertFalse(
            record.contains("\"nudged\""),
            "the field records the policy's verdict; a verdict of true does not guarantee a post")

        // AND THE BOOTSTRAP INSTALL IS DELIBERATELY OUT OF SCOPE. `loadInitialSharedState` assigns
        // the resident directly and seeds the baseline beside it, so the startup reload takes the
        // no-op path and the recorder never runs (Codex, PR #647). Counting it would overstate the
        // alternative being measured: dropping the policy would post from the recorder, which a
        // bootstrap install does not reach either, and `startTunnel` posts settings itself there.
        let load = try sourceBlock(
            in: provider,
            startingAt: "func loadInitialSharedState() -> Bool {",
            endingBefore: "cancelTransientBootstrapDNSWait(reason: \"loadInitialSharedState\")")
        XCTAssertFalse(
            sourceCodeOnly(load).contains("adoptedSnapshotCount"),
            "a bootstrap install is not a nudge-eligible adoption; incrementing here would make the "
                + "measured rate overstate the cost of nudging on every adoption")
    }

    /// The delta has to survive export, or the log says a nudge fired without saying why.
    ///
    /// An emitted-but-unlisted detail key exports as `_withheld`. That has now shipped three times
    /// in this codebase, so the keys go in with the event rather than after it.
    func testTheNudgeEvidenceReachesABugReport() throws {
        let bundle = try readSource(.bugReportBundle)
        let allowlist = try sourceBlock(
            in: bundle,
            startingAt: "private static let allowedDetailKeys: Set<String> = [",
            endingBefore: "private static let structuralKeys")

        for key in [
            "blockRuleCount",
            "allowRuleCount",
            "previousBlockRuleCount",
            "previousAllowRuleCount",
            "guardrailRuleCount",
            "previousGuardrailRuleCount",
            "recoveringFromFailClosed",
            "adoptionCount",
            "loosened"
        ] {
            XCTAssertTrue(
                allowlist.contains("\"\(key)\""),
                "\(key) is emitted by ruleset-loosened-nudge but not exported — the capture would "
                    + "carry `_withheld` where the before/after delta should be")
        }
    }
}
