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
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let applyBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func applyConfiguration(to manager: NETunnelProviderManager)",
            endingBefore: "func saveAndReload"
        )
        XCTAssertFalse(applyBlock.contains("isOnDemandEnabled = true"))
        XCTAssertFalse(applyBlock.contains("NEOnDemandRuleConnect()"))
    }

    func testEnableConfiguresConnectOnDemandAfterConnect() throws {
        // On-demand is enabled in enableProtection only after the tunnel is
        // confirmed connected, and before protectionEnabled is persisted.
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let enableBlock = try Self.sourceBlock(
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
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func disableProtection(operationID:",
            endingBefore: "private func reconnectProtectionNow"
        )
        let disableOnDemandIndex = try XCTUnwrap(disableBlock.range(of: "setManagerOnDemand(false")?.lowerBound)
        let stopIndex = try XCTUnwrap(disableBlock.range(of: "manager?.connection.stopVPNTunnel()")?.lowerBound)
        XCTAssertLessThan(
            disableOnDemandIndex, stopIndex,
            "Turn-off must disable on-demand before stopping, or iOS immediately reconnects."
        )
    }

    func testReconnectDisablesOnDemandBeforeStopping() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let reconnectBlock = try Self.sourceBlock(
            in: source,
            startingAt: "vpnMessage = \"Reconnecting local protection...\"",
            endingBefore: "await enableProtection(logUserAction: false"
        )
        let disableOnDemandIndex = try XCTUnwrap(reconnectBlock.range(of: "setManagerOnDemand(false")?.lowerBound)
        let stopIndex = try XCTUnwrap(reconnectBlock.range(of: "manager?.connection.stopVPNTunnel()")?.lowerBound)
        XCTAssertLessThan(disableOnDemandIndex, stopIndex)
    }

    func testSetManagerOnDemandHelperSetsAndPersistsTheFlag() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // iOS only honors on-demand after a save, so the helper must both set the
        // flag and persist it.
        XCTAssertTrue(source.contains("manager.isOnDemandEnabled = enabled"))
        XCTAssertTrue(source.contains("private func setManagerOnDemand("))
    }

    func testLaunchReconcilesTunnelSnapshotWhenAlreadyConnected() throws {
        // On-demand persists across restarts, so on launch iOS can bring the
        // tunnel up cold — it loads fail-closed and never recovers on its own,
        // because restoreProtectionIfNeeded early-returns once the tunnel reads
        // as connected and a non-stale launch never re-pushes. The launch flow
        // must re-establish and push the snapshot when protection is active.
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        XCTAssertTrue(
            source.contains("await reconcileTunnelSnapshotAfterLaunch()"),
            "The reconcile must be wired into the launch (loadVPNState) task chain."
        )

        let reconcileBlock = try Self.sourceBlock(
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
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
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
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let launchBlock = try Self.sourceBlock(
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
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
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
    }

    func testRestoreProtectionIsGatedOnOnboardingCompletion() throws {
        // restoreProtectionIfNeeded is called from the launch catalog sync
        // (performCatalogSync) and the filter-apply path. During incomplete
        // onboarding it must NOT enable protection: a concurrent startup status
        // refresh can read an inherited on-demand manager as connected and make
        // the caller's shouldRestoreProtection true, which would otherwise drive
        // enableProtection -> saveToPreferences (the VPN prompt) before the
        // onboarding VPN step. The onboarding gate must precede the enable call.
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
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
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
            in: source,
            startingAt: "private var hasCompletedOnboarding: Bool",
            endingBefore: "private func neutralizeInheritedProtectionDuringOnboarding"
        )
        XCTAssertTrue(block.contains("UserDefaults.standard.bool(forKey: \"hasSeenLavaOnboarding\")"))
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        guard endMarker != "*** end ***" else {
            return String(suffix)
        }

        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
