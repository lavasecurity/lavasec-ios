import XCTest
@testable import LavaSecCore

/// The app target is outside SwiftPM, so these narrow source pins supplement the executable
/// sidecar-store contract. They lock the lifecycle fence/order that a value-type unit test cannot
/// observe: the durable user decision must land before the stop/disarm edge, while no sidecar
/// write may touch the generation-owned configuration/library pair.
final class ProtectionRestoreIntentSourceTests: XCTestCase {
    func testStoreUsesAtomicControlPlaneWriteAndNeverTouchesTheFocusOwnedPair() throws {
        let store = try readSource(.protectionRestoreIntentStore)
        let invariants = try readSource(.invariants)

        XCTAssertTrue(store.contains("public static let filename = \"protection-restore-intent.json\""))
        XCTAssertTrue(store.contains("SharedStateFileReader.fileExistsButIsUnreadable(at: url"))
        XCTAssertTrue(
            sourceContainsInOrder([
                "static var atomicWritingOptions",
                "SharedStateFileProtection.atomicControlPlaneWritingOptions",
                "data.write(to: url, options: atomicWritingOptions)",
            ], in: store),
            "The durable explicit intent must use the crash-safe Class-None control-plane write."
        )
        XCTAssertFalse(store.contains("SharedFilterStatePersistence"))
        XCTAssertFalse(store.contains("configurationGeneration"))
        XCTAssertFalse(store.contains("filter-library.json"))
        XCTAssertTrue(invariants.contains("### INV-PERSIST-3 — Explicit protection restore intent is durable and pair-isolated"))
        XCTAssertTrue(invariants.contains("`protection-restore-intent.json`"))
        XCTAssertTrue(invariants.contains("restore-ineligible"))
    }

    func testLaunchAndPostUnlockRecoveryUseDurableIntentPolicy() throws {
        let source = try readAppViewModelSource()
        let initBlock = try sourceBlock(
            in: source,
            startingAt: "init(loadVPNState: Bool = true, headless: Bool = false, platformServices: LavaAppPlatformServices? = nil) {",
            endingBefore: "deinit {"
        )
        let reload = try sourceBlock(
            in: source,
            startingAt: "func reloadSharedStateIfBlockedByDataProtection() {",
            endingBefore: "private func loadOrMigrateFilterLibrary()"
        )
        let recover = try sourceBlock(
            in: source,
            startingAt: "func recoverUserProtectionIntentFromDurableState()",
            endingBefore: "/// Load the filter library, or (first launch on a multi-filter build, or a"
        )

        let initLoad = try XCTUnwrap(initBlock.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let initIntent = try XCTUnwrap(
            initBlock.range(of: "recoverUserProtectionIntentFromDurableState()")?.lowerBound
        )
        XCTAssertLessThan(initLoad, initIntent)

        let reloadLoad = try XCTUnwrap(reload.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let reloadIntent = try XCTUnwrap(
            reload.range(of: "recoverUserProtectionIntentFromDurableState()")?.lowerBound
        )
        XCTAssertLessThan(reloadLoad, reloadIntent)

        XCTAssertTrue(recover.contains("case .absent:"))
        XCTAssertTrue(recover.contains("configuration.protectionEnabled"), "Only an ABSENT sidecar may use the legacy fallback.")
        XCTAssertTrue(recover.contains("case let .stored(isEnabled):"))
        XCTAssertTrue(recover.contains("case .corrupt:"))
        XCTAssertTrue(recover.contains("case .unreadable:"))
        XCTAssertTrue(recover.contains("recoverFromLoadedConfiguration(isEnabled: false)"))
        XCTAssertTrue(recover.contains("event: \"protection-restore-intent-corrupt-at-load\""))
        XCTAssertTrue(recover.contains("event: \"protection-restore-intent-unreadable-at-load\""))
        XCTAssertFalse(recover.contains("url.path"), "The diagnostic breadcrumb must not expose an App Group path.")
        XCTAssertFalse(recover.contains("\"error\":"), "The diagnostic breadcrumb must not export a raw filesystem I/O error.")
        XCTAssertFalse(recover.contains("persistConfigurationOnly"))
        XCTAssertFalse(recover.contains("persistSharedState"))
    }

    func testAcceptedOffPersistsInsideOwnedFenceBeforeEveryTeardownSideEffect() throws {
        let source = try readAppViewModelSource()
        let disable = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow("
        )

        let fence = try XCTUnwrap(disable.range(of: "withExclusiveProtectionLifecycleMutation")?.lowerBound)
        let disableOuterFence = try sourceBlock(
            in: disable,
            startingAt: "if !lifecycleMutationFenceIsOwned {",
            endingBefore: "let trace = makeLatencyTrace"
        )
        let persist = try XCTUnwrap(
            disable.range(of: "try persistExplicitProtectionIntent(isEnabled: false)")?.lowerBound
        )
        let managerLoad = try XCTUnwrap(
            disable.range(of: "loadExistingTunnelManager()", range: persist..<disable.endIndex)?.lowerBound
        )
        let sessionEnd = try XCTUnwrap(
            disable.range(of: "endProtectionVPNSession()", range: persist..<disable.endIndex)?.lowerBound
        )
        let onDemandDisable = try XCTUnwrap(
            disable.range(of: "on: manager, clearsStrictRouting: persistsExplicitIntent", range: persist..<disable.endIndex)?.lowerBound
        )
        let stop = try XCTUnwrap(
            disable.range(of: "manager?.connection.stopVPNTunnel()", range: persist..<disable.endIndex)?.lowerBound
        )
        let profileRemoval = try XCTUnwrap(
            disable.range(of: "guard await forceRemoveStuckProtectionProfile() else", range: persist..<disable.endIndex)?.lowerBound
        )

        XCTAssertLessThan(fence, persist, "The OFF crash barrier belongs to the already-owned lifecycle fence.")
        XCTAssertTrue(
            disableOuterFence.contains("persistsExplicitIntent: persistsExplicitIntent"),
            "The outer fence recursion must forward explicit OFF rather than silently defaulting it to false."
        )
        XCTAssertLessThan(persist, managerLoad)
        XCTAssertLessThan(persist, sessionEnd)
        XCTAssertLessThan(persist, onDemandDisable)
        XCTAssertLessThan(persist, stop)
        XCTAssertLessThan(persist, profileRemoval)
        XCTAssertTrue(disable.contains("prefix: \"Could not stop protection\".lavaLocalized"))
    }

    func testExplicitOnAndUserReconnectPersistTrueBeforeTheirLifecycleMutations() throws {
        let source = try readAppViewModelSource()
        let actions = try sourceBlock(
            in: source,
            startingAt: "func turnOffProtection()",
            endingBefore: "// MARK: - Onboarding"
        )
        let enable = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        let reconnect = try sourceBlock(
            in: source,
            startingAt: "func reconnectProtectionNow(",
            endingBefore: "private func waitForProtectionToConnect("
        )
        let automaticRestore = try sourceBlock(
            in: source,
            startingAt: "func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async",
            endingBefore: "func reconcileTunnelSnapshotAfterLaunch() async"
        )
        let probe = try sourceBlock(
            in: source,
            startingAt: "func runVPNStartupDebugProbe() async",
            endingBefore: "private func runVPNLifecycleSmokeProbe() async"
        )

        XCTAssertTrue(actions.contains("await disableProtection(persistsExplicitIntent: true)"))
        XCTAssertTrue(actions.contains("await enableProtection(persistsExplicitIntent: true)"))
        XCTAssertTrue(actions.contains("await reconnectProtectionNow(persistsExplicitIntent: true)"))
        XCTAssertTrue(enable.contains("persistsExplicitIntent: Bool = false"))
        XCTAssertTrue(reconnect.contains("persistsExplicitIntent: Bool = false"))

        let enablePersist = try XCTUnwrap(
            enable.range(of: "try persistExplicitProtectionIntent(isEnabled: true)")?.lowerBound
        )
        let enableOuterFence = try sourceBlock(
            in: enable,
            startingAt: "if continueIfLifecycleLeaseOwned == nil, !lifecycleMutationFenceIsOwned {",
            endingBefore: "func shouldContinueProtectionLifecycle()"
        )
        let prepareChainedStart = try XCTUnwrap(
            enable.range(of: "prepareChainedStateForExplicitGuardStart()", range: enablePersist..<enable.endIndex)?.lowerBound
        )
        let enablePairPersist = try XCTUnwrap(
            enable.range(of: "try await persistSharedState(", range: enablePersist..<enable.endIndex)?.lowerBound
        )
        let enableManager = try XCTUnwrap(
            enable.range(of: "loadExistingTunnelManager()", range: enablePersist..<enable.endIndex)?.lowerBound
        )
        let enableStart = try XCTUnwrap(
            enable.range(of: "manager.connection.startVPNTunnel", range: enablePersist..<enable.endIndex)?.lowerBound
        )
        XCTAssertTrue(
            enableOuterFence.contains("persistsExplicitIntent: persistsExplicitIntent"),
            "The outer enable fence recursion must retain the accepted explicit ON bit."
        )
        XCTAssertLessThan(enablePersist, prepareChainedStart)
        XCTAssertLessThan(enablePersist, enablePairPersist)
        XCTAssertLessThan(enablePersist, enableManager)
        XCTAssertLessThan(enablePersist, enableStart)
        XCTAssertTrue(enable.contains("prefix: \"Could not start protection\".lavaLocalized"))

        let reconnectPersist = try XCTUnwrap(
            reconnect.range(of: "try persistExplicitProtectionIntent(isEnabled: true)")?.lowerBound
        )
        let reconnectOuterFence = try sourceBlock(
            in: reconnect,
            startingAt: "if !lifecycleMutationFenceIsOwned {",
            endingBefore: "#if DEBUG"
        )
        let reconnectManager = try XCTUnwrap(
            reconnect.range(of: "loadExistingTunnelManager()", range: reconnectPersist..<reconnect.endIndex)?.lowerBound
        )
        let reconnectOnDemand = try XCTUnwrap(
            reconnect.range(of: "disableOnDemandWithRetry(on: manager)", range: reconnectPersist..<reconnect.endIndex)?.lowerBound
        )
        let reconnectStop = try XCTUnwrap(
            reconnect.range(of: "manager?.connection.stopVPNTunnel()", range: reconnectPersist..<reconnect.endIndex)?.lowerBound
        )
        XCTAssertLessThan(reconnectPersist, reconnectManager)
        XCTAssertLessThan(reconnectPersist, reconnectOnDemand)
        XCTAssertLessThan(reconnectPersist, reconnectStop)
        XCTAssertTrue(
            reconnectOuterFence.contains("persistsExplicitIntent: persistsExplicitIntent"),
            "The outer reconnect fence recursion must retain the accepted explicit ON bit."
        )
        XCTAssertTrue(reconnect.contains("prefix: \"Could not reconnect protection\".lavaLocalized"))

        XCTAssertTrue(automaticRestore.contains("persistsExplicitIntent: false"))
        XCTAssertFalse(probe.contains("persistsExplicitIntent: true"), "QA/system probes must not rewrite explicit user intent.")
    }
}
