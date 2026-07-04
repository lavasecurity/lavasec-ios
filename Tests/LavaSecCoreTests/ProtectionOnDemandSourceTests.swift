import XCTest
@testable import LavaSecCore

/// Guards the Connect-On-Demand correctness invariants. On-demand is set on the
/// NETunnelProviderManager (app target), so it is verified by source shape: the
/// behavior that matters is that on-demand is enabled on connect and, crucially,
/// disabled BEFORE any stop — otherwise iOS reconnects and the VPN cannot be
/// turned off.
final class ProtectionOnDemandSourceTests: XCTestCase {
    func testApplyConfigurationDoesNotEnableOnDemand() throws {
        // applyConfiguration is the shared install/enable path: it also runs when
        // onboarding merely installs the VPN profile, before the user turns
        // protection on. Enabling on-demand there makes iOS bring the tunnel up
        // immediately on a fresh install (protection appears "on" with a filter
        // that is red and no working internet), so it must NOT enable on-demand.
        let source = try readSource(.appViewModel)
        let applyBlock = try sourceBlock(
            in: source,
            startingAt: "func applyConfiguration(to manager: NETunnelProviderManager)",
            endingBefore: "func saveAndReload"
        )
        XCTAssertFalse(applyBlock.contains("isOnDemandEnabled = true"))
        XCTAssertFalse(applyBlock.contains("NEOnDemandRuleConnect()"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("isOnDemandEnabled"))
    }

    func testEnableConfiguresConnectOnDemandAfterConnect() throws {
        // On-demand is enabled in enableProtection only after the tunnel is
        // confirmed connected, and before protectionEnabled is persisted.
        let source = try readSource(.appViewModel)
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "private func enableProtection(",
            endingBefore: "private func disableProtection(operationID:"
        )
        let enableOnDemandIndex = try XCTUnwrap(enableBlock.range(of: "setManagerOnDemand(true")?.lowerBound)
        let protectionEnabledIndex = try XCTUnwrap(enableBlock.range(of: "configuration.protectionEnabled = true")?.lowerBound)
        XCTAssertLessThan(
            enableOnDemandIndex, protectionEnabledIndex,
            "On-demand must be enabled once the tunnel is connected, as part of turn-on."
        )
    }

    func testTurnOffDisablesOnDemandBeforeStopping() throws {
        let source = try readSource(.appViewModel)
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "private func disableProtection(operationID:",
            endingBefore: "private func reconnectProtectionNow"
        )
        let disableOnDemandIndex = try XCTUnwrap(disableBlock.range(of: "disableOnDemandWithRetry(on:")?.lowerBound)
        let stopIndex = try XCTUnwrap(disableBlock.range(of: "manager?.connection.stopVPNTunnel()")?.lowerBound)
        XCTAssertLessThan(
            disableOnDemandIndex, stopIndex,
            "Turn-off must disable on-demand before stopping, or iOS immediately reconnects."
        )
    }

    func testReconnectDisablesOnDemandBeforeStopping() throws {
        let source = try readSource(.appViewModel)
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "vpnMessage = \"Reconnecting local protection...\"",
            endingBefore: "await enableProtection(logUserAction: false"
        )
        let disableOnDemandIndex = try XCTUnwrap(reconnectBlock.range(of: "disableOnDemandWithRetry(on:")?.lowerBound)
        let stopIndex = try XCTUnwrap(reconnectBlock.range(of: "manager?.connection.stopVPNTunnel()")?.lowerBound)
        XCTAssertLessThan(disableOnDemandIndex, stopIndex)
    }

    func testTurnOffRetriesOnDemandDisableBeforeFallingThrough() throws {
        // Hardening for UR-31/UR-32: a transient on-demand-disable failure is what
        // wedges turn-off, so the disable retries before the stop instead of
        // swallowing the first error. The helper still delegates to the
        // set+persist helper and only gives up after retrying.
        let source = try readSource(.appViewModel)
        XCTAssertTrue(source.contains("private func disableOnDemandWithRetry("))
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func disableOnDemandWithRetry(",
            endingBefore: "private func reloadManagerFromPreferences"
        )
        XCTAssertTrue(
            helperBlock.contains("try await setManagerOnDemand(false, on: manager)"),
            "Retry wrapper must delegate to the set+persist on-demand helper."
        )
        XCTAssertTrue(
            helperBlock.contains("Task.sleep"),
            "Retry wrapper must back off between attempts."
        )
        XCTAssertTrue(
            helperBlock.contains("reloadManagerFromPreferences(manager)"),
            "Retry must refresh the manager from preferences between attempts — a stale configuration would otherwise make every retry repeat the same failing save."
        )
    }

    func testSetManagerOnDemandHelperSetsAndPersistsTheFlag() throws {
        let source = try readSource(.appViewModel)
        // iOS only honors on-demand after a save, so the helper must both set the
        // flag and persist it.
        XCTAssertTrue(source.contains("manager.isOnDemandEnabled = enabled"))
        XCTAssertTrue(source.contains("private func setManagerOnDemand("))
    }

    /// An armed-but-dropped tunnel (`.disconnected` + confirmed on-demand) must persist
    /// `protectionEnabled = true`, not merely render as "Reconnecting": the tunnel's own
    /// self-reconnect (`TunnelSelfReconnectPolicy`) hard-requires the persisted hint, so a filter
    /// edit/switch during the drop that wrote a false hint would suppress future self-reconnects
    /// even though the user never turned protection off (Codex #262 P2).
    func testProtectionEnabledHintPreservedWhileAwaitingOnDemandReconnect() throws {
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionOnSucceededHapticIfNeeded("
        )
        XCTAssertTrue(
            block.contains("let protectionEnabled = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect"),
            "The persisted protectionEnabled hint must keep the armed-reconnect state true, not derive from vpnStatus alone."
        )
        // Codex #262 P2: the cached confirmed-on-demand bit must be RECONCILED against the live
        // manager so an externally-disabled on-demand (or re-added profile) can't leave a stale
        // `true` that shows "Reconnecting" / persists protectionEnabled=true with nothing armed.
        // Clear-direction only (race-safe vs an in-flight app arm, which sets isOnDemandEnabled
        // true in-memory before its save).
        XCTAssertTrue(
            block.contains("if !manager.isOnDemandEnabled, Self.isOnDemandConfirmedEnabled() {")
                && block.contains("Self.setOnDemandConfirmedEnabled(false)"),
            "A disconnected manager whose on-demand is no longer armed must clear the stale confirmed-on-demand bit before deriving the reconnecting state."
        )
    }

    /// The armed-reconnect state must be honored across the lifecycle restore/enable paths too, not
    /// just the persist derivation — otherwise the preserved hint drives a redundant enableProtection
    /// whose no-network start-timeout re-persists `protectionEnabled = false`, undoing it and
    /// suppressing the self-reconnect (Codex #262 P2 follow-up).
    func testAwaitingOnDemandReconnectHonoredInRestoreAndEnableTimeout() throws {
        let source = try readSource(.appViewModel)
        // Restore treats armed-reconnect as already-active (iOS will reconnect) — it must not force enable.
        let restoreBlock = try sourceBlock(
            in: source,
            startingAt: "private func restoreProtectionIfNeeded(wasEnabled: Bool) async",
            endingBefore: "private func reconcileTunnelSnapshotAfterLaunch"
        )
        XCTAssertTrue(
            restoreBlock.contains("guard !isProtectionEnabledStatus(vpnStatus), !isAwaitingOnDemandReconnect else"),
            "Restore must skip enableProtection while awaiting an on-demand reconnect."
        )
        // The enable start-timeout keeps the hint true when on-demand is armed.
        XCTAssertTrue(
            source.contains("configuration.protectionEnabled = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect"),
            "The enable start-timeout persist must preserve the armed-reconnect hint."
        )
    }

    func testLaunchReconcilesTunnelSnapshotWhenAlreadyConnected() throws {
        // On-demand persists across restarts, so on launch iOS can bring the
        // tunnel up cold — it loads fail-closed and never recovers on its own,
        // because restoreProtectionIfNeeded early-returns once the tunnel reads
        // as connected and a non-stale launch never re-pushes. The launch flow
        // must re-establish and push the snapshot when protection is active.
        let source = try readSource(.appViewModel)
        XCTAssertTrue(
            source.contains("await reconcileTunnelSnapshotAfterLaunch()"),
            "The reconcile must be wired into the launch (loadVPNState) task chain."
        )

        let reconcileBlock = try sourceBlock(
            in: source,
            startingAt: "private func reconcileTunnelSnapshotAfterLaunch() async",
            endingBefore: "private func sendTunnelMessage("
        )
        XCTAssertTrue(
            reconcileBlock.contains("guard isProtectionEnabledStatus(vpnStatus) else"),
            "Reconcile must only act when protection is already active."
        )
        let prepareIndex = try XCTUnwrap(reconcileBlock.range(of: "preparedSnapshotForProtectionStartup()")?.lowerBound)
        let persistIndex = try XCTUnwrap(reconcileBlock.range(of: "persistSharedState(")?.lowerBound)
        let pushIndex = try XCTUnwrap(reconcileBlock.range(of: "notifyTunnelSnapshotUpdated()")?.lowerBound)
        XCTAssertLessThan(prepareIndex, persistIndex)
        XCTAssertLessThan(
            persistIndex, pushIndex,
            "Reconcile must prepare + persist a snapshot, then push it so the tunnel reloads out of fail-closed."
        )
    }

    func testEnablingProtectionDoesNotPromptForNotifications() throws {
        // Notification authorization is requested only at the onboarding
        // notifications step (and contextually on first delivery), never as a
        // side effect of enabling/restoring protection — otherwise the system
        // dialog surfaces at the wrong moment (before the notifications step, or
        // on auto-restore at launch).
        let source = try readSource(.appViewModel)
        XCTAssertFalse(
            source.contains("prepareAuthorizationIfNeeded"),
            "enableProtection must not prepare/request notification authorization."
        )
    }

    func testLaunchGatesProtectionWorkOnOnboardingCompletion() throws {
        // The VPN restore/reconcile launch chain runs from init regardless of the
        // onboarding UI. If onboarding is NOT complete it must not reconcile/treat
        // protection as active — it must instead neutralize any inherited config —
        // so a stale/reinstalled VPN profile cannot bring a fail-closed tunnel up
        // mid-onboarding (the "fresh install shows VPN on / filters red" bug).
        //
        // Ordering matters two ways:
        //   1. Neutralize runs in the not-yet-onboarded branch BEFORE the
        //      network-bound catalog work (loadCachedCatalogIfAvailable /
        //      syncCatalogIfStale), so an inherited fail-closed tunnel is torn
        //      down ASAP and cannot linger while the catalog syncs.
        //   2. Reconcile runs only when onboarding is complete, and AFTER the
        //      catalog work (it needs a snapshot to push).
        let source = try readSource(.appViewModel)
        let launchBlock = try sourceBlock(
            in: source,
            startingAt: "if loadVPNState {",
            endingBefore: "vpnStatusObserver = NotificationCenter"
        )
        let neutralizeGateIndex = try XCTUnwrap(launchBlock.range(of: "if !hasCompletedOnboarding {")?.lowerBound)
        let neutralizeIndex = try XCTUnwrap(launchBlock.range(of: "await neutralizeInheritedProtectionDuringOnboarding()")?.lowerBound)
        let syncIndex = try XCTUnwrap(launchBlock.range(of: "await syncCatalogIfStale()")?.lowerBound)
        let reconcileGateIndex = try XCTUnwrap(launchBlock.range(of: "if hasCompletedOnboarding {")?.lowerBound)
        let reconcileIndex = try XCTUnwrap(launchBlock.range(of: "await reconcileTunnelSnapshotAfterLaunch()")?.lowerBound)

        XCTAssertLessThan(neutralizeGateIndex, neutralizeIndex, "Neutralize is the not-yet-onboarded branch.")
        XCTAssertLessThan(
            neutralizeIndex, syncIndex,
            "Neutralize must run before the network-bound catalog work, so an inherited tunnel cannot linger."
        )
        XCTAssertLessThan(
            syncIndex, reconcileGateIndex,
            "Reconcile is gated after the catalog work (it needs a snapshot to push)."
        )
        XCTAssertLessThan(reconcileGateIndex, reconcileIndex, "Reconcile must run only when onboarding is complete.")
    }

    func testOnboardingNeutralizeRemovesInheritedManagerWithoutSaving() throws {
        // The inherited orphaned config must be REMOVED (removeFromPreferences),
        // not modified-and-saved. saveToPreferences (which setManagerOnDemand
        // uses) re-shows the "Add VPN Configurations" system prompt on a profile
        // this install does not own — surfacing it mid-onboarding (the "VPN prompt
        // at step 1" bug). removeFromPreferences is silent.
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func neutralizeInheritedProtectionDuringOnboarding() async",
            endingBefore: "private func sendTunnelMessage("
        )
        XCTAssertTrue(
            block.contains("loadExistingTunnelManager()"),
            "Neutralize must act on the existing inherited manager (no-op if none)."
        )
        XCTAssertTrue(
            block.contains("guard wasOnDemand || isUpOrComingUp else"),
            "Neutralize must no-op when the inherited config is already inert (clean onboarding)."
        )
        XCTAssertFalse(
            block.contains("setManagerOnDemand(false"),
            "Neutralize must NOT save a change to the orphaned config — saveToPreferences re-prompts for VPN permission mid-onboarding. Remove it instead."
        )
        let stopIndex = try XCTUnwrap(block.range(of: "manager.connection.stopVPNTunnel()")?.lowerBound)
        let removeIndex = try XCTUnwrap(block.range(of: "removeManager(manager)")?.lowerBound)
        XCTAssertLessThan(
            stopIndex, removeIndex,
            "Stop the tunnel, then remove the inherited config."
        )
        XCTAssertTrue(
            block.contains("tunnelManager = nil"),
            "After removal there is no manager — clear the cached reference."
        )
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("setManagerOnDemand"))
    }

    func testRestoreProtectionIsGatedOnOnboardingCompletion() throws {
        // restoreProtectionIfNeeded is called from the launch catalog sync
        // (performCatalogSync) and the filter-apply path. During incomplete
        // onboarding it must NOT enable protection: a concurrent startup status
        // refresh can read an inherited on-demand manager as connected and make
        // the caller's shouldRestoreProtection true, which would otherwise drive
        // enableProtection -> saveToPreferences (the VPN prompt) before the
        // onboarding VPN step. The onboarding gate must precede the enable call.
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private func restoreProtectionIfNeeded(wasEnabled: Bool) async",
            endingBefore: "private func reconcileTunnelSnapshotAfterLaunch"
        )
        let onboardingGate = try XCTUnwrap(block.range(of: "guard hasCompletedOnboarding else")?.lowerBound)
        let enableCall = try XCTUnwrap(block.range(of: "enableProtection(")?.lowerBound)
        XCTAssertLessThan(
            onboardingGate, enableCall,
            "Restore must bail on incomplete onboarding before it can enableProtection."
        )
    }

    func testHasCompletedOnboardingReadsOnboardingFlag() throws {
        // The gate must read the same flag RootView's @AppStorage onboarding gate
        // uses, so the launch chain and the UI agree on "onboarding complete".
        let source = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: source,
            startingAt: "private var hasCompletedOnboarding: Bool",
            endingBefore: "private func neutralizeInheritedProtectionDuringOnboarding"
        )
        XCTAssertTrue(block.contains("UserDefaults.standard.bool(forKey: \"hasSeenLavaOnboarding\")"))
    }

    func testTurnOffRecoversWhenStopDoesNotComplete() throws {
        // Regression for UR-31/UR-32: if the tunnel never reaches a stopped state
        // (e.g. on-demand could not be disabled and iOS keeps reasserting a dead
        // tunnel), turn-off must not dead-end at "Could not stop protection" and
        // leave the user offline. It must attempt to delete the stuck profile to
        // restore connectivity before surfacing the failure.
        let source = try readSource(.appViewModel)
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "private func disableProtection(operationID:",
            endingBefore: "private func reconnectProtectionNow"
        )
        let recoveryIndex = try XCTUnwrap(
            disableBlock.range(of: "forceRemoveStuckProtectionProfile()")?.lowerBound,
            "Turn-off must attempt profile-removal recovery when the stop does not complete."
        )
        let throwIndex = try XCTUnwrap(
            disableBlock.range(of: "throw LavaSecAppError.vpnStillStopping")?.lowerBound
        )
        XCTAssertLessThan(
            recoveryIndex, throwIndex,
            "Recovery must be attempted before giving up with vpnStillStopping."
        )
    }

    func testForceRemoveRecoveryDeletesProfileAndClearsState() throws {
        // The recovery helper must actually delete the profile (removeManager) so
        // the stuck on-demand rules are cleared, and reset protection to stopped.
        let source = try readSource(.appViewModel)
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func forceRemoveStuckProtectionProfile()",
            endingBefore: "private func resumeTemporaryProtectionIfExpired"
        )
        XCTAssertTrue(
            helperBlock.contains("vpnLifecycleController.removeManager(manager)"),
            "Recovery must delete the tunnel profile to clear stuck on-demand rules."
        )
        XCTAssertTrue(
            helperBlock.contains("vpnStatus = .disconnected"),
            "Recovery must reset protection to a stopped state."
        )
    }
}
