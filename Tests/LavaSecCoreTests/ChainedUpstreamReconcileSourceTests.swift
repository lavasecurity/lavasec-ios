import Foundation
import XCTest

@testable import LavaSecCore

/// Pins the app-side wiring for the chaining disable reconcile (plan D2's surviving
/// Plus-lapse leg).
///
/// The decision is executable-tested in `ChainedUpstreamReconcileTests`; `AppViewModel` sits
/// outside the SPM test target, so the call site and its ORDERING can only be held as text.
/// Ordering is the part worth pinning: the reconcile is correct only if it lands inside the
/// same configuration write as the entitlement change it reacts to.
final class ChainedUpstreamReconcileSourceTests: XCTestCase {
    func testALapseClearsTheChainingFlagInTheSameWrite() throws {
        let app = try readAppViewModelSource()
        let block = try sourceBlock(
            in: app,
            startingAt: "func persistPaidPlanFlag(_ isPaid: Bool) throws {",
            endingBefore: "// MARK: - Account hub bridge"
        )

        let paidIdx = try XCTUnwrap(block.range(of: "configuration.isPaid = isPaid")?.lowerBound)
        let reconcileIdx = try XCTUnwrap(
            block.range(of: "reconcileChainedUpstreamAfterEligibilityChange(reason: \"plan-changed\")")?.lowerBound
        )
        let persistIdx = try XCTUnwrap(block.range(of: "try persistConfigurationOnly()")?.lowerBound)

        XCTAssertLessThan(paidIdx, reconcileIdx, "The reconcile must see the NEW entitlement, not the old one.")
        XCTAssertLessThan(
            reconcileIdx,
            persistIdx,
            "The reconcile must run BEFORE the persist so the lapse and the disable are one "
                + "atomic write. After it, the flag would outlive the entitlement on disk and "
                + "cost a second generation bump, lock acquisition, and backup schedule."
        )
        let refreshIdx = try XCTUnwrap(block.range(of: "refreshDNSSettingsPresentation()")?.lowerBound)
        let rollbackIdx = try XCTUnwrap(block.range(of: "configuration.isPaid = previousIsPaid")?.lowerBound)
        XCTAssertLessThan(persistIdx, refreshIdx, "Publish VPN eligibility only after the plan write succeeds.")
        XCTAssertLessThan(rollbackIdx, refreshIdx, "A failed write must restore the plan before returning to its cached presentation.")
        XCTAssertTrue(block.contains("if previousIsPaid != configuration.isPaid || previousChainedUpstreamEnabled != configuration.chainedUpstreamEnabled"),
                      "Unchanged entitlement checks must not reread VPN credentials.")
    }

    /// A failed lapse write rolls BOTH flags back, and retracts the log line it already wrote.
    ///
    /// The retraction has to be decided BEFORE the restore, and this pin exists because the
    /// first version was not: written after it, the condition read
    /// `previousChainedUpstreamEnabled && !configuration.chainedUpstreamEnabled` — `x && !x`,
    /// dead code that claimed to fix a misleading log and changed nothing. Both reviewers
    /// found it independently; nothing in the suite did (Codex and Kilo, PR #519).
    func testAFailedLapseWriteRollsBackAndRetractsItsBreadcrumb() throws {
        let source = try readAppViewModelSource()
        let persist = try sourceBlock(
            in: source,
            startingAt: "func persistPaidPlanFlag(_ isPaid: Bool) throws {",
            endingBefore: "// MARK: - Account hub bridge")
        // Both flags captured before the mutation, and both restored on a throw — the
        // in-memory state must not describe a write that did not land.
        XCTAssertTrue(persist.contains("let previousIsPaid = configuration.isPaid"))
        XCTAssertTrue(
            persist.contains(
                "let previousChainedUpstreamEnabled = configuration.chainedUpstreamEnabled"))
        XCTAssertTrue(persist.contains("configuration.isPaid = previousIsPaid"))

        let decide = try XCTUnwrap(
            persist.range(of: "let didDisable = previousChainedUpstreamEnabled"),
            "the retraction must be decided from the flag, not re-derived after it moves")
        let restore = try XCTUnwrap(
            persist.range(
                of: "configuration.chainedUpstreamEnabled = previousChainedUpstreamEnabled"))
        XCTAssertLessThan(
            decide.lowerBound, restore.lowerBound,
            "deciding after the restore makes the condition x && !x — it can never fire")

        let emit = try XCTUnwrap(
            persist.range(of: "chained-upstream-disable-rolled-back"))
        XCTAssertLessThan(restore.lowerBound, emit.lowerBound)
    }

    func testTheReconcileDelegatesToThePolicyAndWritesNoUserFacingCopy() throws {
        let app = try readAppViewModelSource()
        let block = try sourceBlock(
            in: app,
            startingAt: "func reconcileChainedUpstreamAfterEligibilityChange(reason: String) {",
            endingBefore: "/// Compact filter-rule count for tight UI"
        )

        XCTAssertTrue(
            block.contains("ChainedAvailability.reconcile("),
            "The which-causes-revoke decision belongs to the tested policy, not to the hub."
        )
        XCTAssertTrue(
            block.contains("guard case .disable(let cause) = outcome else {"),
            "Only a .disable outcome may touch the configuration."
        )
        XCTAssertTrue(
            block.contains("configuration.chainedUpstreamEnabled = false"),
            "A revoking cause must actually clear the stored preference."
        )

        // Phase 2 is string-free by requirement: the localization gate rejects untranslated
        // user copy, and the Phase-4/5 pass owns the explanation. The adjacent tier reconcile
        // writes catalogStatusMessage — including one unlocalized literal — so the nearest
        // model to copy is exactly the one that must not be copied here.
        for surface in ["catalogStatusMessage", "catalogStatusIsError", "vpnMessage", ".lavaLocalized"] {
            XCTAssertFalse(
                block.contains(surface),
                "The Phase-2 reconcile must stay string-free; `\(surface)` is user-facing copy."
            )
        }
        XCTAssertTrue(
            block.contains("logVPNDebugEvent(\"chained-upstream-disabled\""),
            "A silent revocation is undiagnosable in a field log."
        )
    }

    func testTheReconcileDoesNotPersistOrReconnectOnItsOwn() throws {
        let app = try readAppViewModelSource()
        let block = try sourceBlock(
            in: app,
            startingAt: "func reconcileChainedUpstreamAfterEligibilityChange(reason: String) {",
            endingBefore: "/// Compact filter-rule count for tight UI"
        )

        // The caller owns persistence, so this can be folded into an existing write. It also
        // inherits persistPaidPlanFlag's documented no-reload contract: signalling a
        // configuration reload here would reapply tunnel network settings — a visible
        // reconnect — on every entitlement change.
        for forbidden in [
            "persistConfigurationOnly(",
            "persistSharedState(",
            "reconnectProtectionNow(",
            "sendProviderMessage(",
        ] {
            XCTAssertFalse(
                block.contains(forbidden),
                "The reconcile must not `\(forbidden)` — the caller persists, and a reload here "
                    + "would reconnect the tunnel on every entitlement change."
            )
        }
    }

    func testThePlaceholderEligibilityInputsStayCoupledToTheirPhaseFourStores() throws {
        let app = try readAppViewModelSource()
        let block = try sourceBlock(
            in: app,
            startingAt: "func reconcileChainedUpstreamAfterEligibilityChange(reason: String) {",
            endingBefore: "/// Compact filter-rule count for tight UI"
        )

        // Same conditional guard as the tunnel latch's. `false` is the true value while no
        // store exists; once one does, `false` becomes a permissive lie — it would re-admit a
        // device the jetsam backoff excluded, or ignore an override the user set.
        let overrideStoreExists = app.contains("experimentalChainedOverride")
        if overrideStoreExists {
            XCTAssertFalse(
                block.contains("experimentalOverrideEnabled: false"),
                "The override store exists now; the reconcile must read it."
            )
            XCTAssertFalse(
                block.contains("hasStartupCrashLoopTripped: false"),
                "The exclusion marker exists now; the reconcile must read it."
            )
        } else {
            XCTAssertTrue(block.contains("experimentalOverrideEnabled: false"))
            XCTAssertTrue(block.contains("hasStartupCrashLoopTripped: false"))
        }
    }
}
