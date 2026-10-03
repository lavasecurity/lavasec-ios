import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Guards the Connect-On-Demand correctness invariants. On-demand is set on the
/// NETunnelProviderManager (app target), so it is verified by source shape: the
/// behavior that matters is that on-demand is enabled on connect and, crucially,
/// disabled BEFORE any stop — otherwise iOS reconnects and the VPN cannot be
/// turned off.
final class ProtectionOnDemandSourceTests: XCTestCase {
    func testRecoveryIdentityIsCapturedEvenWhileApplicationObservationIsInactive() throws {
        let source = try readAppViewModelSource()
        let sampling = try sourceBlock(in: source,
            startingAt: "private func startChainedLifecycleSampling(connection: UInt64)",
            endingBefore: "private func setChainedObservationActive(")
        let identity = try XCTUnwrap(sampling.range(of: "chainedLifecycleMutationIdentity = ChainedLifecycleMutationIdentity(")?.lowerBound)
        let visibility = try XCTUnwrap(sampling.range(of: "chainedObservationLifetime.beginSampling()")?.lowerBound)
        XCTAssertLessThan(identity, visibility, "background observation cannot suppress the recovery arm identity")
    }

    func testOnDemandConfirmationWaitsForSavedRuleReadback() throws {
        let source = try readAppViewModelSource()
        let setter = try sourceBlock(in: source,
            startingAt: "func setManagerOnDemand(_ enabled: Bool, on manager: NETunnelProviderManager)",
            endingBefore: "private static func setOnDemandConfirmedEnabled(")
        let save = try XCTUnwrap(setter.range(of: "manager.saveToPreferences")?.lowerBound)
        let reload = try XCTUnwrap(setter.range(of: "reloadManagerFromPreferences(manager)")?.lowerBound)
        let confirm = try XCTUnwrap(setter.range(of: "Self.setOnDemandConfirmedEnabled(enabled)")?.lowerBound)
        XCTAssertLessThan(save, reload)
        XCTAssertLessThan(reload, confirm)
        XCTAssertTrue(setter.contains("ProtectionOnDemandArm.Failure.verificationFailed"))
        XCTAssertTrue(setter.contains("NEOnDemandRuleConnect"))
        XCTAssertTrue(setter.contains("ProtectionOnDemandArm.hasUniversalConnectRule"))
        for condition in ["probeURL", "dnsSearchDomainMatch", "dnsServerAddressMatch", "ssidMatch"] {
            XCTAssertTrue(setter.contains("rule.\(condition) != nil"))
        }
    }

    func testForegroundRecoveryRevalidatesDurableIntentAndUsesANewEpochForMissingGeneration() throws {
        let source = try readAppViewModelSource()
        let repair = try sourceBlock(in: source,
            startingAt: "private func requestForegroundOnDemandRepair()",
            endingBefore: "private func stopChainedLifecycleSampling()")
        let refresh = try XCTUnwrap(repair.range(of: "return try await self.loadExistingTunnelManager()")?.lowerBound)
        let admission = try XCTUnwrap(repair.range(of: "applyState: { manager in", range: refresh..<repair.endIndex)?.lowerBound)
        let durable = try XCTUnwrap(repair.range(of: "ProtectionRestoreIntentStore.read(containerURL: containerURL)", range: admission..<repair.endIndex)?.lowerBound)
        let request = try XCTUnwrap(repair.range(of: ".onDemandRepairRequested(connection: connection", range: durable..<repair.endIndex)?.lowerBound)
        XCTAssertLessThan(refresh, admission)
        XCTAssertLessThan(admission, durable)
        XCTAssertLessThan(durable, request)
        XCTAssertTrue(repair.contains("manager?.connection.status == .connected"))
        XCTAssertTrue(repair.contains("self.chainedConnectLifecycleState.onDemandRepairConnection == connection"))
        XCTAssertTrue(repair.contains("self.userProtectionIntent.revision == intentRevision"))
        XCTAssertTrue(repair.contains("self.chainedObservationLifetime.activityGeneration == activityGeneration"))
        XCTAssertFalse(repair.contains("self.chainedObservationLifetime.generation =="),
            "DNS-only sampler shutdown must not retire a live foreground repair")
        XCTAssertTrue(repair.contains("!self.isTearingDownProtection"))
        XCTAssertTrue(repair.contains("self.chainedLifecycleMutationIdentity?.externalRestartGeneration == nil"))
        XCTAssertFalse(repair.contains(".captureExternalRestartGeneration()"), "repair cannot rebase an old identity")
        let active = try sourceBlock(in: source,
            startingAt: "private func setChainedObservationActive(",
            endingBefore: "private func requestForegroundOnDemandRepair()")
        XCTAssertTrue(active.contains("if active { requestForegroundOnDemandRepair() }"))
    }

    func testForegroundRecoveryRequiresASuccessfulSavedManagerRead() throws {
        let source = try readAppViewModelSource()
        let repair = try sourceBlock(in: source,
            startingAt: "private func requestForegroundOnDemandRepair()",
            endingBefore: "private func stopChainedLifecycleSampling()")
        XCTAssertFalse(repair.contains("refreshProtectionStatus("), "refresh may retain a stale cache after a platform load failure")
        let read = try XCTUnwrap(repair.range(of: "return try await self.loadExistingTunnelManager()")?.lowerBound)
        let failure = try XCTUnwrap(repair.range(of: "} catch {", range: read..<repair.endIndex)?.lowerBound)
        let failureThrow = try XCTUnwrap(repair.range(of: "throw error", range: failure..<repair.endIndex)?.lowerBound)
        let observation = try XCTUnwrap(repair.range(of: "self.updateProtectionStatus(from: manager)")?.lowerBound)
        let request = try XCTUnwrap(repair.range(of: ".onDemandRepairRequested(connection: connection")?.lowerBound)
        XCTAssertLessThan(read, failure)
        XCTAssertLessThan(failure, failureThrow)
        XCTAssertLessThan(failureThrow, observation)
        XCTAssertLessThan(observation, request)
        XCTAssertTrue(repair.contains("self.tunnelManager = manager"))
    }

    func testForegroundReadAndPublicationUseTheArmMutationFence() throws {
        let source = try readAppViewModelSource()
        let repair = try sourceBlock(in: source,
            startingAt: "private func requestForegroundOnDemandRepair()",
            endingBefore: "private func stopChainedLifecycleSampling()")
        let fence = try XCTUnwrap(repair.range(of: "LavaProtectionCommandService.refreshOnDemandStateForForegroundRepair(")?.lowerBound)
        let read = try XCTUnwrap(repair.range(of: "readState: {", range: fence..<repair.endIndex)?.lowerBound)
        let load = try XCTUnwrap(repair.range(of: "self.loadExistingTunnelManager()", range: read..<repair.endIndex)?.lowerBound)
        let admission = try XCTUnwrap(repair.range(of: "applyState: { manager in", range: load..<repair.endIndex)?.lowerBound)
        let publication = try XCTUnwrap(repair.range(of: "self.tunnelManager = manager", range: admission..<repair.endIndex)?.lowerBound)
        let reduction = try XCTUnwrap(repair.range(of: ".onDemandRepairRequested(connection: connection", range: publication..<repair.endIndex)?.lowerBound)
        XCTAssertLessThan(fence, read)
        XCTAssertLessThan(read, load)
        XCTAssertLessThan(load, admission)
        XCTAssertLessThan(admission, publication)
        XCTAssertLessThan(publication, reduction)
        XCTAssertFalse(repair[admission..<repair.endIndex].contains("await "),
            "synchronous admission may spawn an arm but cannot await it while owning its fence")
        let service = try readSource(.lavaProtectionCommandService)
        let wrapper = try sourceBlock(in: service,
            startingAt: "static func refreshOnDemandStateForForegroundRepair<Snapshot>(",
            endingBefore: "static func withProtectionLifecyclePreferenceMutation(")
        XCTAssertTrue(wrapper.contains("ProtectionOnDemandArm.refreshForForegroundRepair("))
        XCTAssertTrue(wrapper.contains("lockFileURL: protectionLifecycleMutationLockURL()"))
        XCTAssertTrue(wrapper.contains("readState: readState"))
        XCTAssertTrue(wrapper.contains("applyState: applyState"))
    }

    func testLoadedProfileConfirmationRequiresTheSavedUniversalRecoveryRule() throws {
        let source = try readAppViewModelSource()
        let seed = try sourceBlock(in: source,
            startingAt: "private static func seedOnDemandConfirmedIfAbsent(from manager:",
            endingBefore: "private static let onDemandDisableRetryDelayNanoseconds")
        XCTAssertTrue(seed.contains("manager.isOnDemandEnabled && managerHasUniversalOnDemandRule(manager)"))
        let update = try sourceBlock(in: source,
            startingAt: "func updateProtectionStatus(from manager:",
            endingBefore: "private func playProtectionStartFailedHaptic()")
        XCTAssertTrue(update.contains("let hasArmedRecoveryRule = manager.isOnDemandEnabled && Self.managerHasUniversalOnDemandRule(manager)"))
        XCTAssertTrue(update.contains("if !hasArmedRecoveryRule, Self.isOnDemandConfirmedEnabled() {"))
    }

    func testReducerEffectIsTheOnlyOnDemandArmProducerAndEveryTokenCompletes() throws {
        let source = try readAppViewModelSource()
        let enable = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection(operationID:")
        XCTAssertFalse(
            enable.contains("setManagerOnDemand(true"),
            "enable must observe live runtime truth instead of arming from a saved preference")
        XCTAssertEqual(
            sourceOccurrenceCount(of: "setManagerOnDemand(true", in: source),
            1,
            "the reducer-tokened arm is the only Connect-On-Demand producer")

        let executor = try sourceBlock(
            in: source,
            startingAt: "func executeChainedConnectLifecycleEffects(",
            endingBefore: "private func startChainedLifecycleSampling(connection: UInt64)")
        XCTAssertTrue(executor.contains("for effect in effects"))
        XCTAssertTrue(executor.contains("case let .ensureOnDemand(id, connection):"))
        XCTAssertTrue(executor.contains("startChainedOnDemandArm(id: id, connection: connection)"))

        let arm = try sourceBlock(
            in: source,
            startingAt: "private func startChainedOnDemandArm(id: UInt64, connection: UInt64)",
            endingBefore: "private func completeChainedOnDemandArm(id: UInt64, confirmed: Bool)")
        let deferIndex = try XCTUnwrap(arm.range(of: "defer {")?.lowerBound)
        let predecessorIndex = try XCTUnwrap(arm.range(of: "await previous?.value")?.lowerBound)
        let cancelIndex = try XCTUnwrap(arm.range(of: "previous?.cancel()")?.lowerBound)
        XCTAssertLessThan(deferIndex, predecessorIndex, "predecessor cancellation still finishes the token")
        XCTAssertLessThan(
            cancelIndex,
            predecessorIndex,
            "a replacement must cancel its predecessor before waiting for the transitive drain")
        XCTAssertEqual(
            arm.components(separatedBy: "completeChainedOnDemandArm(id: id, confirmed: confirmed)")
                .count - 1,
            1,
            "one defer is the only completion path, so every exit completes exactly once")
        XCTAssertTrue(arm.contains("manager.isOnDemandEnabled && hasConnectRule"))
        XCTAssertTrue(arm.contains("Self.isOnDemandConfirmedEnabled()"))
        XCTAssertTrue(arm.contains("ProtectionOnDemandArm.perform("))
        XCTAssertTrue(arm.contains("ProtectionRestoreIntentStore.read(containerURL: containerURL)"))
        XCTAssertTrue(arm.contains("confirmed = try await LavaProtectionCommandService"))
        XCTAssertTrue(arm.contains("return try await ProtectionOnDemandArm.perform("),
            "the behavioral repair controller owns already-armed and verified-save confirmation")
        XCTAssertTrue(arm.contains("!Task.isCancelled"))
        XCTAssertTrue(arm.contains("self.isCurrentChainedLifecycleMutation(identity, armID: id)"))
        XCTAssertFalse(arm.contains("configuration."))

        let completion = try sourceBlock(
            in: source,
            startingAt: "private func completeChainedOnDemandArm(id: UInt64, confirmed: Bool)",
            endingBefore: "func beginProtectionTeardown()")
        let identityGuard = try XCTUnwrap(completion.range(of: "if chainedOnDemandArmID == id {")?.lowerBound)
        let taskClear = try XCTUnwrap(
            completion.range(of: "chainedOnDemandArmTask = nil", range: identityGuard..<completion.endIndex)?
                .lowerBound)
        let guardClose = try XCTUnwrap(
            completion.range(of: "        }", range: taskClear..<completion.endIndex)?.lowerBound)
        XCTAssertLessThan(taskClear, guardClose)
        XCTAssertFalse(
            completion[guardClose..<completion.endIndex].contains("chainedOnDemandArmTask = nil"),
            "a stale token cannot discard the newer arm's drain handle")
        XCTAssertTrue(completion.contains(".onDemandArmFinished(id: id, confirmed: confirmed)"))
        XCTAssertTrue(completion.contains("executeChainedConnectLifecycleEffects(effects)"))
    }

    func testReducerArmFencesTheExactConnectionIntentAndRestartGeneration() throws {
        let source = try readAppViewModelSource()
        let sampling = try sourceBlock(
            in: source,
            startingAt: "private func startChainedLifecycleSampling(connection: UInt64)",
            endingBefore: "private func stopChainedLifecycleSampling()")
        let identityIndex = try XCTUnwrap(
            sampling.range(of: "chainedLifecycleMutationIdentity = ChainedLifecycleMutationIdentity(")?
                .lowerBound)
        let taskIndex = try XCTUnwrap(
            sampling.range(of: "chainedLifecycleSamplingTask = Task", range: identityIndex..<sampling.endIndex)?
                .lowerBound)
        XCTAssertLessThan(identityIndex, taskIndex, "identity capture must precede the first suspension")
        XCTAssertTrue(sampling.contains("connection: connection"))
        XCTAssertTrue(sampling.contains("protectionIntentRevision: userProtectionIntent.revision"))
        XCTAssertTrue(sampling.contains(".captureExternalRestartGeneration()"))

        let ownership = try sourceBlock(
            in: source,
            startingAt: "private func isCurrentChainedLifecycleMutation(",
            endingBefore: "private func startChainedOnDemandArm(")
        XCTAssertTrue(ownership.contains("chainedLifecycleMutationIdentity == identity"))
        XCTAssertTrue(ownership.contains("userProtectionIntent.isEnabled"))
        XCTAssertTrue(
            ownership.contains("userProtectionIntent.revision == identity.protectionIntentRevision"))
        XCTAssertTrue(ownership.contains("!isTearingDownProtection"))
        XCTAssertTrue(ownership.contains("vpnStatus == .connected"))
        XCTAssertTrue(ownership.contains("chainedOnDemandArmID == $0"))

        let arm = try sourceBlock(
            in: source,
            startingAt: "private func startChainedOnDemandArm(id: UInt64, connection: UInt64)",
            endingBefore: "private func completeChainedOnDemandArm(id: UInt64, confirmed: Bool)")
        let fenceIndex = try XCTUnwrap(
            arm.range(of: "withProtectionLifecycleDescendantMutation(")?.lowerBound)
        let loadIndex = try XCTUnwrap(
            arm.range(of: "loadExistingTunnelManager()", range: fenceIndex..<arm.endIndex)?.lowerBound)
        let saveIndex = try XCTUnwrap(
            arm.range(of: "setManagerOnDemand(true, on: manager)", range: loadIndex..<arm.endIndex)?
                .lowerBound)
        XCTAssertLessThan(fenceIndex, loadIndex)
        XCTAssertLessThan(loadIndex, saveIndex)
        XCTAssertTrue(arm.contains("validateOwnership: {"), "the behavioral repair controller checks ownership after every suspension")
        XCTAssertTrue(arm.contains("capturedGeneration: externalRestartGeneration"))
        XCTAssertTrue(arm.contains("identity.connection == connection"))
        XCTAssertTrue(arm.contains("let externalRestartGeneration = identity.externalRestartGeneration"))
    }

    func testTeardownDepthEdgesSuspendTheReducerBeforeAnyAwait() throws {
        let source = try readAppViewModelSource()
        let begin = try sourceBlock(
            in: source,
            startingAt: "func beginProtectionTeardown()",
            endingBefore: "func endProtectionTeardown()")
        XCTAssertTrue(begin.contains("let wasInactive = protectionTeardownDepth == 0"))
        XCTAssertTrue(begin.contains("protectionTeardownDepth += 1"))
        XCTAssertTrue(begin.contains(".teardownChanged(isActive: true)"))

        let end = try sourceBlock(
            in: source,
            startingAt: "func endProtectionTeardown()",
            endingBefore: "func drainChainedOnDemandArm() async")
        XCTAssertTrue(end.contains("protectionTeardownDepth -= 1"))
        XCTAssertTrue(end.contains("if protectionTeardownDepth == 0"))
        XCTAssertTrue(end.contains(".teardownChanged(isActive: false)"))

        let disable = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow")
        let disableBegin = try XCTUnwrap(disable.range(of: "beginProtectionTeardown()")?.lowerBound)
        let disableMessage = try XCTUnwrap(
            disable.range(of: "vpnMessage = \"Stopping local protection...\"")?.lowerBound)
        let disableLoad = try XCTUnwrap(disable.range(of: "loadExistingTunnelManager()")?.lowerBound)
        let disableDrain = try XCTUnwrap(
            disable.range(of: "await drainChainedOnDemandArm()")?.lowerBound)
        XCTAssertLessThan(disableBegin, disableMessage)
        XCTAssertLessThan(disableBegin, disableLoad)
        XCTAssertLessThan(disableBegin, disableDrain)
        XCTAssertTrue(disable.contains("defer { endProtectionTeardown() }"))

        let reconnect = try sourceBlock(
            in: source,
            startingAt: "func reconnectProtectionNow(",
            endingBefore: "private func waitForProtectionToConnect(")
        let reconnectBegin = try XCTUnwrap(
            reconnect.range(of: "beginProtectionTeardown()")?.lowerBound)
        let outerDrain = try XCTUnwrap(
            reconnect.range(of: "await drainChainedOnDemandArm()", range: reconnectBegin..<reconnect.endIndex)?
                .lowerBound)
        let fence = try XCTUnwrap(
            reconnect.range(
                of: "withExclusiveProtectionLifecycleMutation",
                range: outerDrain..<reconnect.endIndex)?.lowerBound)
        let transfer = try XCTUnwrap(
            reconnect.range(of: "preflightTeardownIsActive = false", range: fence..<reconnect.endIndex)?
                .lowerBound)
        let recursiveCall = try XCTUnwrap(
            reconnect.range(of: "await self.reconnectProtectionNow(", range: transfer..<reconnect.endIndex)?
                .lowerBound)
        XCTAssertLessThan(reconnectBegin, outerDrain)
        XCTAssertLessThan(outerDrain, fence)
        XCTAssertLessThan(fence, transfer)
        XCTAssertLessThan(transfer, recursiveCall)
        XCTAssertFalse(
            reconnect[transfer..<recursiveCall].contains("endProtectionTeardown()"),
            "the preflight teardown edge must transfer without briefly resuming reducer producers")
        XCTAssertTrue(reconnect.contains("protectionTeardownIsOwned: true"))

        let reconnectLoad = try XCTUnwrap(reconnect.range(of: "loadExistingTunnelManager()")?.lowerBound)
        let suspendedScopeStart = try XCTUnwrap(
            reconnect.range(of: "            do {\n                if protectionTeardownIsOwned {")?
                .lowerBound)
        let suspendedScopeEnd = try XCTUnwrap(
            reconnect.range(of: "\n            }\n            guard continueIfCurrent?() ?? true else { return }")?.lowerBound)
        let reconnectEnable = try XCTUnwrap(
            reconnect.range(of: "await enableProtection(", range: suspendedScopeEnd..<reconnect.endIndex)?
                .lowerBound)
        XCTAssertLessThan(suspendedScopeStart, reconnectLoad)
        XCTAssertLessThan(reconnectLoad, suspendedScopeEnd)
        XCTAssertLessThan(
            suspendedScopeEnd,
            reconnectEnable,
            "the reducer suspension must end before the replacement connect can emit a fresh arm")
        XCTAssertLessThan(reconnectLoad, reconnectEnable)
        XCTAssertTrue(reconnect.contains("defer { endProtectionTeardown() }"))
        XCTAssertFalse(sourceCodeOnly(disable).contains("cancelChainedEstablishmentGate"))
    }

    func testEveryOnDemandDisableDrainsTheTransitiveArmFirst() throws {
        let source = try readAppViewModelSource()
        for (start, end) in [
            ("func disableProtection(", "func reconnectProtectionNow"),
            (
                "func reconnectProtectionNow(",
                "private func waitForProtectionToConnect("
            ),
        ] {
            let block = try sourceBlock(in: source, startingAt: start, endingBefore: end)
            let drain = try XCTUnwrap(block.range(of: "await drainChainedOnDemandArm()")?.lowerBound)
            let disable = try XCTUnwrap(block.range(of: "disableOnDemandWithRetry(on:")?.lowerBound)
            XCTAssertLessThan(drain, disable)
        }

        let drain = try sourceBlock(
            in: source,
            startingAt: "func drainChainedOnDemandArm() async",
            endingBefore: "// MARK: - App Store review prompting")
        let cancel = try XCTUnwrap(drain.range(of: "task.cancel()")?.lowerBound)
        let wait = try XCTUnwrap(drain.range(of: "await task.value")?.lowerBound)
        XCTAssertLessThan(cancel, wait)
        XCTAssertTrue(drain.contains("while let task = chainedOnDemandArmTask"))
        XCTAssertTrue(drain.contains("if chainedOnDemandArmTask == task"))
        XCTAssertTrue(drain.contains("chainedOnDemandArmID = nil"))
    }

    func testApplyConfigurationDoesNotEnableOnDemand() throws {
        let source = try readAppViewModelSource()
        let apply = try sourceBlock(
            in: source,
            startingAt: "func applyConfiguration(to manager: NETunnelProviderManager)",
            endingBefore: "func saveAndReload")
        XCTAssertFalse(apply.contains("isOnDemandEnabled = true"))
        XCTAssertFalse(apply.contains("NEOnDemandRuleConnect()"))
        XCTAssertTrue(source.contains("isOnDemandEnabled"))
    }

    func testTurnOffDisablesOnDemandBeforeStopping() throws {
        let source = try readAppViewModelSource()
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(operationID:",
            endingBefore: "func reconnectProtectionNow"
        )
        let disableOnDemandIndex = try XCTUnwrap(disableBlock.range(of: "disableOnDemandWithRetry(on:")?.lowerBound)
        let stopIndex = try XCTUnwrap(disableBlock.range(of: "manager?.connection.stopVPNTunnel()")?.lowerBound)
        XCTAssertLessThan(
            disableOnDemandIndex, stopIndex,
            "Turn-off must disable on-demand before stopping, or iOS immediately reconnects."
        )
    }

    func testReconnectDisablesOnDemandBeforeStopping() throws {
        let source = try readAppViewModelSource()
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "vpnMessage = \"Reconnecting local protection...\"",
            endingBefore: "await enableProtection("
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
        let source = try readAppViewModelSource()
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
        let source = try readAppViewModelSource()
        // iOS only honors on-demand after a save, so the helper must both set the
        // flag and persist it.
        XCTAssertTrue(source.contains("manager.isOnDemandEnabled = enabled"))
        XCTAssertTrue(source.contains("func setManagerOnDemand("))
    }

    /// An armed-but-dropped tunnel (`.disconnected` + confirmed on-demand) must persist
    /// `protectionEnabled = true`, not merely render as "Reconnecting": the tunnel's own
    /// self-reconnect (`TunnelSelfReconnectPolicy`) hard-requires the persisted hint, so a filter
    /// edit/switch during the drop that wrote a false hint would suppress future self-reconnects
    /// even though the user never turned protection off (Codex #262 P2).
    func testProtectionEnabledHintPreservedWhileAwaitingOnDemandReconnect() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()"
        )
        XCTAssertTrue(
            block.contains("let protectionEnabled = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect"),
            "The persisted protectionEnabled hint must keep the armed-reconnect state true, not derive from vpnStatus alone."
        )
        // Codex #262 P2: the cached confirmed-on-demand bit must be RECONCILED against the live
        // manager so an externally-disabled on-demand (or re-added profile) can't leave a stale
        // `true` that shows "Reconnecting" / persists protectionEnabled=true with nothing armed.
        // Clear-direction only (race-safe vs an in-flight app arm, which installs the unconditional
        // rule and sets isOnDemandEnabled true in-memory before its save).
        // Prove the clear sits INSIDE the !hasArmedRecoveryRule guard body, not merely somewhere in the
        // method — there are other setOnDemandConfirmedEnabled(false) calls in AppViewModel (the arm
        // flow), so two independent `contains` would pass even if this clear were hoisted out of the
        // guard to run unconditionally (which would clobber an in-flight app arm).
        let reconcileGuard = try XCTUnwrap(
            block.range(of: "if !hasArmedRecoveryRule, Self.isOnDemandConfirmedEnabled() {"),
            "A disconnected manager whose on-demand is no longer armed must clear the stale confirmed-on-demand bit before deriving the reconnecting state.")
        let afterGuard = block[reconcileGuard.upperBound...]
        // Anchor the guard's closing brace at ITS indentation (12 spaces) rather than the first `}`,
        // so a future nested brace-delimited block in the guard body (deeper-indented) can't be
        // mistaken for the guard close and truncate the slice before the clear call. (#44 OCR)
        let guardClose = try XCTUnwrap(afterGuard.range(of: "\n            }")?.lowerBound)
        XCTAssertTrue(
            afterGuard[..<guardClose].contains("Self.setOnDemandConfirmedEnabled(false)"),
            "The stale-bit clear must sit INSIDE the !hasArmedRecoveryRule guard body (clear-direction only), not run unconditionally.")
        // …and it must run BEFORE the protectionEnabled derivation reads isAwaitingOnDemandReconnect
        // (which reads the bit). If the reconcile were moved below the derivation, an externally
        // disabled profile would still derive protectionEnabled=true off the stale bit (Codex).
        let derivationIndex = try XCTUnwrap(
            block.range(of: "let protectionEnabled = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect")?.lowerBound)
        XCTAssertLessThan(
            reconcileGuard.lowerBound, derivationIndex,
            "The stale-bit reconcile must run BEFORE the protectionEnabled derivation, else the derivation reads the stale confirmed-on-demand bit.")
    }

    /// FAIL CLOSED. A recorded chained refusal is disclosed, never turned into an automatic
    /// OFF: the provider starts the latched DNS-only path under any refusal, so the app keeps
    /// the user's intent, the profile and Connect-On-Demand exactly as they were. Only an
    /// explicit user action turns protection off
    /// (plans/2026-09-18-fail-closed-protection-startup-failures-plan.md).
    func testAChainedStartupFailureDisclosesWithoutDisarmingOnDemand() throws {
        let source = try readAppViewModelSource()
        let status = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()"
        )
        XCTAssertTrue(status.contains("let markerObservation = chainedStartupFailureMarkerObservation"))
        XCTAssertTrue(status.contains("if configuration.chainedUpstreamEnabled, case .marked = markerObservation"))
        XCTAssertTrue(status.contains("chainedStartupFailureNotice = Self.chainedStartupFailureMessage.lavaLocalized"))
        XCTAssertFalse(status.contains("if startupFailureIsTerminal"),
            "a recorded refusal must not project protection off")
        XCTAssertFalse(status.contains("configuration.protectionEnabled = false"),
            "the marker projection must never turn protection off")

        let notice = try sourceBlock(
            in: status,
            startingAt: "if configuration.chainedUpstreamEnabled, case .marked = markerObservation",
            endingBefore: "let protectionEnabled = isProtectionEnabledStatus"
        )
        for destructive in [
            "persistExplicitProtectionIntent(isEnabled: false)",
            "disableOnDemandWithRetry", "forceRemoveStuckProtectionProfile",
            "stopVPNTunnel", "recordUserIntent(isEnabled: false)",
            "setOnDemandConfirmedEnabled(false)",
        ] {
            XCTAssertFalse(notice.contains(destructive),
                "a startup failure must never perform \(destructive); only an explicit user action turns protection off")
        }
        XCTAssertFalse(source.contains("reconcileChainedStartupFailureIfNeeded("),
            "the destructive reconciliation machinery is removed, not merely unreachable")
    }

    /// A transient marker read must not present an armed profile as fully off.
    ///
    /// `.unavailable` is fail-closed for automatic RESTORE — enforced separately in
    /// `restoreProtectionIfNeeded` — but this is the PRESENTATION term, and the profile really is
    /// armed. Collapsing a briefly busy lock into the fully-off branch shows [Turn On] over an
    /// armed profile, and releasing the marker lock publishes nothing observable, so the surface
    /// can stay wrong and route a tap into enable instead of letting the user turn it off.
    func testOnlyAConfirmedMarkerRetiresTheArmedReconnectSurface() throws {
        let source = try readAppViewModelSource()
        let awaiting = try sourceBlock(
            in: source,
            startingAt: "    var isAwaitingOnDemandReconnect: Bool {",
            endingBefore: "/// The unconfirmed surface speaks only where")
        XCTAssertTrue(
            awaiting.contains("chainedStartupFailureMarkerObservation.terminalReason == nil"),
            "only a CONFIRMED terminal refusal may retire the armed-reconnect presentation")
        // The cheap policy term still gates the marker read, so a body pass does not pay an
        // App Group file open under a `flock` on the main actor.
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "ProtectionLifecyclePolicy.isAwaitingOnDemandReconnect(",
                    "chainedStartupFailureMarkerObservation",
                ], in: awaiting),
            "the cheap lifecycle term must be evaluated before the marker read")
    }

    func testAutomaticRestoreIsNotBlockedByAStandingChainedRefusal() throws {
        let source = try readAppViewModelSource()
        let restore = try sourceBlock(
            in: source,
            startingAt: "func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async",
            endingBefore: "func reconcileTunnelSnapshotAfterLaunch() async"
        )
        XCTAssertFalse(
            restore.contains("ChainedStartupFailureMarker.isMarked("),
            "a standing refusal must not block automatic restore: the provider starts DNS-only")
        XCTAssertTrue(
            restore.contains("guard request.wasEnabled, request.intendedEnabled else"),
            "restore still requires the user's enabled intent")
    }

    /// The armed-reconnect state must be honored across the lifecycle restore/enable paths too, not
    /// just the persist derivation — otherwise the preserved hint drives a redundant enableProtection
    /// whose no-network start-timeout re-persists `protectionEnabled = false`, undoing it and
    /// suppressing the self-reconnect (Codex #262 P2 follow-up).
    func testAwaitingOnDemandReconnectHonoredInRestoreAndEnableTimeout() throws {
        let source = try readAppViewModelSource()
        // Restore treats armed-reconnect as already-active (iOS will reconnect) — it must not force enable.
        let restoreBlock = try sourceBlock(
            in: source,
            startingAt: "func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async",
            endingBefore: "func reconcileTunnelSnapshotAfterLaunch() async"
        )
        XCTAssertTrue(restoreBlock.contains("runAutomaticRestoreAfterRefresh("))
        XCTAssertTrue(restoreBlock.contains("&& !self.isAwaitingOnDemandReconnect"),
                      "The post-refresh live predicate must skip while on-demand is already reconnecting.")
        XCTAssertTrue(restoreBlock.contains("self.userProtectionIntent.allows(request)"),
                      "The post-refresh predicate must use explicit revisioned intent, not the status-derived configuration mirror.")
        XCTAssertFalse(restoreBlock.contains("self.configuration.protectionEnabled"))
        // The enable start-timeout keeps the hint true when on-demand is armed. Scope to
        // enableProtection: the same expression also appears in updateProtectionStatus, so an
        // unscoped `source.contains` could pass on the wrong site if this one regressed.
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        XCTAssertTrue(
            enableBlock.contains("configuration.protectionEnabled = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect"),
            "The enable start-timeout persist must preserve the armed-reconnect hint."
        )
    }

    func testLaunchReconcilesTunnelSnapshotWhenAlreadyConnected() throws {
        // On-demand persists across restarts, so on launch iOS can bring the
        // tunnel up cold — it loads fail-closed and never recovers on its own,
        // because restoreProtectionIfNeeded early-returns once the tunnel reads
        // as connected and a non-stale launch never re-pushes. The launch flow
        // must re-establish and push the snapshot when protection is active.
        let source = try readAppViewModelSource()
        XCTAssertTrue(
            source.contains("await reconcileTunnelSnapshotAfterLaunch()"),
            "The reconcile must be wired into the launch (loadVPNState) task chain."
        )

        let reconcileBlock = try sourceBlock(
            in: source,
            startingAt: "func reconcileTunnelSnapshotAfterLaunch() async",
            endingBefore: "func sendTunnelMessage("
        )
        XCTAssertTrue(
            reconcileBlock.contains("guard isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect else"),
            "Reconcile must act when protection is active OR armed-but-dropped — an armed-reconnect launch must publish the snapshot BEFORE iOS reconnects, else the tunnel starts cold on stale/fail-closed rules (Codex #44 P2)."
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
        let source = try readAppViewModelSource()
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
        let source = try readAppViewModelSource()
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
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "func neutralizeInheritedProtectionDuringOnboarding() async",
            endingBefore: "func sendTunnelMessage("
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
        // the caller's restore request to carry wasEnabled=true, which would otherwise drive
        // enableProtection -> saveToPreferences (the VPN prompt) before the
        // onboarding VPN step. The onboarding gate must precede the enable call.
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async",
            endingBefore: "func reconcileTunnelSnapshotAfterLaunch() async"
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
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "var hasCompletedOnboarding: Bool",
            endingBefore: "func neutralizeInheritedProtectionDuringOnboarding"
        )
        XCTAssertTrue(block.contains("UserDefaults.standard.bool(forKey: \"hasSeenLavaOnboarding\")"))
    }

    func testTurnOffRecoversWhenStopDoesNotComplete() throws {
        // Regression for UR-31/UR-32: if the tunnel never reaches a stopped state
        // (e.g. on-demand could not be disabled and iOS keeps reasserting a dead
        // tunnel), turn-off must not dead-end at "Could not stop protection" and
        // leave the user offline. It must attempt to delete the stuck profile to
        // restore connectivity before surfacing the failure.
        let source = try readAppViewModelSource()
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(operationID:",
            endingBefore: "func reconnectProtectionNow"
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

    func testTurnOffForceRemovesWhenOnDemandDisableFailsEvenIfAlreadyStopped() throws {
        // Regression (#44 Codex P2): the reconnecting turn-off routes an armed-but-dropped tunnel
        // (already `.disconnected`) through disableProtection. There `waitForProtectionToStop()`
        // returns true immediately, so a `== false` gate would SKIP the force-remove backstop — yet a
        // failed on-demand disable leaves the saved profile armed and iOS re-arms the tunnel, so the
        // user can't actually turn protection off. disableProtection must capture the disable result
        // and force-remove when it failed, not only when the tunnel is stuck running.
        let source = try readAppViewModelSource()
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(operationID:",
            endingBefore: "func reconnectProtectionNow"
        )
        XCTAssertTrue(
            disableBlock.contains("onDemandDisabled = await disableOnDemandWithRetry(")
                && disableBlock.contains("on: manager, clearsStrictRouting: persistsExplicitIntent"),
            "disableProtection must capture whether on-demand actually got disabled (its result must not be ignored)."
        )
        // The backstop seeds on `!onDemandDisabled` (so a failed disable forces removal even when the
        // tunnel is already stopped) and still fires when the tunnel never stops. (Branched rather than
        // `|| await …` because `await` can't sit in a `||` autoclosure.)
        XCTAssertTrue(
            disableBlock.contains("var mustForceRemoveProfile = !onDemandDisabled"),
            "The force-remove backstop must seed on !onDemandDisabled, so an armed-but-dropped turn-off with a failed on-demand disable can't leave the profile re-arming."
        )
        XCTAssertTrue(
            disableBlock.contains("mustForceRemoveProfile = await waitForProtectionToStop() == false"),
            "The backstop must also fire when the tunnel never reaches a stopped state."
        )
    }

    func testForceRemoveRecoveryDeletesProfileAndClearsState() throws {
        // The recovery helper must actually delete the profile (removeManager) so
        // the stuck on-demand rules are cleared, and reset protection to stopped.
        let source = try readAppViewModelSource()
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func forceRemoveStuckProtectionProfile()",
            endingBefore: "func resumeTemporaryProtectionIfExpired"
        )
        XCTAssertTrue(
            helperBlock.contains("vpnLifecycleController.removeManager(manager)"),
            "Recovery must delete the tunnel profile to clear stuck on-demand rules."
        )
        let managerClear = try XCTUnwrap(helperBlock.range(of: "tunnelManager = nil")?.lowerBound)
        let statusFunnel = try XCTUnwrap(
            helperBlock.range(of: "updateProtectionStatus(from: nil)")?.lowerBound)
        XCTAssertLessThan(managerClear, statusFunnel)
        XCTAssertFalse(
            sourceCodeOnly(helperBlock).contains("vpnStatus = .disconnected"),
            "preassigning the status hides the connected-to-terminal edge that cancels diagnostics")
    }
    /// A SILENT Focus apply failure is recorded where a Release build can see it.
    ///
    /// The catch in `switchToFilter` rolls back and discards `error`. Its only trace was
    /// `reconcile-apply-failed-kept-marker` via `logFocusSwitchEvent`, which is
    /// `#if DEBUG || LAVA_QA_TOOLS` — so on a shipping build a Focus automation that never applies
    /// produced no log, no modal and no banner. Device 2026-08-29: 44 attempts across six builds
    /// and five days, zero successes, cause unknown because nothing kept it (PR #625).
    ///
    /// Pinned rather than executed because `AppViewModel` is an app-target type the SPM test
    /// target does not link; the recorder itself has executable coverage in
    /// `FocusSwitchDiagnosticsTests`.
    func testASilentFocusApplyFailureIsRecordedForRelease() throws {
        let source = try readAppViewModelSource()
        let catchBlock = try sourceBlock(
            in: source,
            startingAt: "            try? persistConfigurationOnly(rejectsAdvancedBeyond: rollbackGeneration)",
            endingBefore: "if presentsPreparationCover {")
        XCTAssertTrue(
            catchBlock.contains("FocusSwitchDiagnostics.recordForegroundReconcileFailure("),
            "the caught error must reach the Release-visible slot before the silent path drops it")
        XCTAssertTrue(
            catchBlock.contains("if !presentsPreparationCover, let failureEvent {"),
            "scoped to the SILENT path — a user-initiated failure already shows a cover, and "
                + "writing there too lets ordinary foreground failures evict the automation record")
        XCTAssertTrue(
            catchBlock.contains("reason: Self.focusReconcileFailureReason(for: failureError)"),
            "the reason must be CLASSIFIED, never the raw error")
        XCTAssertTrue(
            source.contains("let diagnosticEvent = diagnosticOrderingLockURL.flatMap")
                && source.contains("FocusSwitchDiagnostics.captureEvent("),
            "the failure event must be captured before the async preparation can hand it off")
        XCTAssertTrue(
            catchBlock.contains("at: failureEvent.at")
                && catchBlock.contains("clearGeneration: failureEvent.clearGeneration"),
            "the failure must carry its producer-boundary event across the MainActor handoff")
        XCTAssertTrue(
            catchBlock.contains("Self.withFocusDiagnosticsConsent { consented in"),
            "the write must answer the user's standing consent, not assume it")
        let persistBlock = try sourceBlock(
            in: source,
            startingAt: "func persistSharedState(",
            endingBefore: "func persistConfigurationOnly(")
        let persistCode = sourceCodeOnly(persistBlock)
        let producerBoundary = try XCTUnwrap(persistCode.range(of: "do {")?.lowerBound)
        let configurationWrite = try XCTUnwrap(
            persistCode.range(of: "SharedFilterStatePersistence.writeConfigurationAndLibrary(")?.lowerBound)
        let artifactPublish = try XCTUnwrap(
            persistCode.range(of: "persistPreparedSnapshotArtifacts(")?.lowerBound)
        let diagnosticCatch = try XCTUnwrap(
            persistCode.range(
                of: "} catch let cancellation as CancellationError {",
                range: artifactPublish..<persistCode.endIndex)?.lowerBound)
        XCTAssertLessThan(producerBoundary, configurationWrite)
        XCTAssertLessThan(configurationWrite, artifactPublish)
        XCTAssertLessThan(
            artifactPublish, diagnosticCatch,
            "The foreground diagnostic boundary must cover the config write and artifact publish.")
        XCTAssertTrue(persistCode.contains("} catch let diagnosticFailure as FocusSwitchDiagnosticFailure {"))
        // 🔴 LIVE CONFIGURATION MERGE. `previousConfiguration` predates the switch, so only its
        // filter-plan fields may be restored. The live device-global values, including a Network
        // Activity opt-out made while preparation was suspended, must reach this persist unchanged
        // (Codex, PR #625).
        let switchBlock = try sourceBlock(
            in: source,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "enum SwitchPublication")
        let switchCode = sourceCodeOnly(switchBlock)
        let rollback = try XCTUnwrap(
            switchCode.range(of: "configuration = applyingFilterPlan(from: previousConfiguration, onto: configuration)")?.lowerBound)
        let persist = try XCTUnwrap(
            switchCode.range(of: "try? persistConfigurationOnly(rejectsAdvancedBeyond: rollbackGeneration)", range: rollback..<switchCode.endIndex)?
                .lowerBound)
        XCTAssertLessThan(
            rollback, persist,
            "the live-preserving rollback merge must precede its durable persist")
        XCTAssertFalse(
            switchCode.contains("configuration.keepNetworkActivity ="),
            "the merge must preserve Network Activity without a per-field re-apply")

        // RULE 7, both hooks. A Release-persisted record has to be reachable by the user's own
        // erase gestures, and the write has to STOP while consent is withdrawn — a clear the next
        // write undoes is theatre.
        let toggleOff = try sourceBlock(
            in: source,
            startingAt: "        if !keepNetworkActivity && clearActivity {",
            endingBefore: "func setKeepLavaGuardProgress(")
        XCTAssertTrue(
            toggleOff.contains("FocusSwitchDiagnostics.clear(in: LavaSecAppGroup.sharedDefaults)"),
            "turning Network Activity off must clear the Focus diagnostics too")

        // 🔴 THE PRIVACY PROPERTY, and the reason the classifier exists at all: this value is
        // surfaced in the redacted bug report, and `String(describing: error)` on these paths can
        // carry a container path, a catalog URL or a user-chosen filter name.
        let classifier = try sourceBlock(
            in: source,
            startingAt: "    static func focusReconcileFailureReason(for error: Error) -> String {",
            endingBefore: "static func filterPreparationFailureMessage(")
        XCTAssertFalse(
            classifier.contains("\\(error)"),
            "interpolating the error itself can leak a path, a URL or a filter name into a record "
                + "that ships in the bug report")
        XCTAssertTrue(
            classifier.contains("String(describing: type(of: error))"),
            "the fallback carries the error's TYPE only — groupable, and incapable of content")

        // 🔴 THE PREPARATION ERRORS MUST BE SPLIT BY CASE. `prepareSwitchPublication` is the most
        // likely thrower on this path, and one `other:BlocklistCatalogSyncError` would name eleven
        // different actionable failures — a checksum mismatch, a rule-limit overflow and a missing
        // source are different bugs with different fixes (Codex, PR #625).
        for expected in [
            "catalog-http-status", "catalog-invalid", "blocklist-encoding", "blocklist-too-large",
            "blocklist-rule-limit", "blocklist-checksum-mismatch", "blocklist-no-accepted-hashes",
            "blocklist-source-missing", "catalog-not-cached", "no-rules-available",
            "custom-blocklist-unavailable",
            // "your phone can't" and "your plan won't" are different answers to the user, so they
            // may not share a key (Codex, PR #625).
            "prepare-device-memory-budget", "prepare-tier-rule-limit",
        ] {
            XCTAssertTrue(
                classifier.contains("return \"\(expected)\""),
                "\(expected) is not distinguishable — it would collapse into the other: bucket")
        }
        // CASE ONLY, NEVER THE PAYLOAD: EIGHT of the eleven cases carry associated values, FIVE of
        // them a catalog `sourceID`, and `customBlocklistUnavailable` a name the USER typed.
        // Binding any of them is how user text reaches a record that ships in the redacted bug
        // report.
        // 🔴 CODE ONLY. The comment above the switch names `customBlocklistUnavailable(displayName:)`
        // to explain WHY the payload is dropped, so scanning the raw block matches the prose and
        // fails on a correct implementation — the mirror of the vacuous-match defect, and the same
        // root cause: matching text instead of a construct.
        let classifierCode = sourceCodeOnly(classifier)
        for binding in ["sourceID:", "displayName:", "(let ", "(sourceID", "(displayName"] {
            XCTAssertFalse(
                classifierCode.contains(binding),
                "the classifier binds an associated value (\(binding)) — case names only")
        }
    }

    /// A failed filter switch must not revert the user's privacy opt-out.
    ///
    /// 🔴 THE ROLLBACK IS ABOUT THE FILTER. `previousConfiguration` is captured before the switch
    /// begins, so only its filter-plan fields may be merged back. The live configuration must keep
    /// a Network Activity opt-out made while the apply was suspended, including when the rollback
    /// is persisted (Codex, PR #625).
    func testAFailedSwitchDoesNotRevertThePrivacyOptOut() throws {
        let source = try readAppViewModelSource()
        let switchBlock = try sourceBlock(
            in: source,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "enum SwitchPublication")
        let switchCode = sourceCodeOnly(switchBlock)
        XCTAssertTrue(
            switchCode.contains("configuration = applyingFilterPlan(from: previousConfiguration, onto: configuration)"),
            "the rollback must merge the previous filter plan into the live configuration")
        XCTAssertFalse(
            switchCode.contains("configuration = previousConfiguration"),
            "the rollback must not replace live privacy settings with the entry snapshot")
        XCTAssertFalse(
            switchCode.contains("configuration = nextConfiguration"),
            "the commit must not replace live privacy settings with the entry snapshot")
        let restoreCapture = try XCTUnwrap(switchCode.range(of: "let restoreRequest = makeProtectionRestoreRequest()")?.lowerBound)
        let prepare = try XCTUnwrap(switchCode.range(of: "try await prepareSwitchPublication")?.lowerBound)
        XCTAssertLessThan(restoreCapture, prepare,
                          "Protection intent + revision must be captured before switch preparation suspends.")
        XCTAssertTrue(switchCode.contains("await restoreProtectionIfNeeded(restoreRequest)"))
        XCTAssertFalse(
            switchCode.contains("wasEnabled: configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)"),
            "The post-prepare status mirror must not replace the captured explicit user intent.")

        let merge = try sourceBlock(
            in: source,
            startingAt: "private func applyingFilterPlan(",
            endingBefore: "enum SwitchPublication")
        XCTAssertFalse(
            sourceCodeOnly(merge).contains("keepNetworkActivity"),
            "the merge must preserve the live Network Activity consent without a per-field re-apply")

        let rollback = try sourceBlock(
            in: switchBlock,
            startingAt: "configuration = applyingFilterPlan(from: previousConfiguration, onto: configuration)",
            endingBefore: "try? persistConfigurationOnly(rejectsAdvancedBeyond: rollbackGeneration)")
        XCTAssertTrue(
            rollback.contains("configuration = applyingFilterPlan(from: previousConfiguration, onto: configuration)"),
            "the rollback must preserve the live privacy setting before it persists")

        // 🔴 BOTH BRANCHES. The commit and rollback must merge their entry snapshots' filter plans
        // into the live configuration before their respective persists, so every device-global
        // setting changed during preparation survives durably (Codex, PR #625).
        let commit = try sourceBlock(
            in: switchBlock,
            startingAt: "var switchConfiguration = applyingFilterPlan(from: nextConfiguration, onto: configuration)",
            endingBefore: "library.setActiveFilter(id: id)")
        XCTAssertTrue(
            commit.contains("configuration = switchConfiguration"),
            "the commit must install the merged filter plan only after preparation")

        // ORDER MATTERS: both merges have to land before their persist, or a stale value reaches disk.
        let reapply = try XCTUnwrap(
            switchCode.range(of: "configuration = applyingFilterPlan(from: previousConfiguration, onto: configuration)")?.lowerBound)
        let persist = try XCTUnwrap(
            switchCode.range(of: "try? persistConfigurationOnly(rejectsAdvancedBeyond: rollbackGeneration)", range: reapply..<switchCode.endIndex)?
                .lowerBound)
        XCTAssertLessThan(reapply, persist)

        let commitMerge = try XCTUnwrap(
            switchCode.range(of: "configuration = switchConfiguration")?.lowerBound)
        let sharedPersist = try XCTUnwrap(
            switchCode.range(of: "try await persistSharedState(", range: commitMerge..<switchCode.endIndex)?
                .lowerBound)
        XCTAssertLessThan(commitMerge, sharedPersist)
    }

    /// An opt-out that did not persist is not treated as consent withdrawn.
    ///
    /// 🔴 THE ON-DISK COPY IS WHAT ANOTHER PROCESS READS. `HeadlessFocusFilterSwitchEngine` runs in
    /// the App Intents extension and loads `keepNetworkActivity` from the shared configuration
    /// file, so an in-memory flag that flipped while the write failed leaves the writer reading
    /// `true`: the clears run, the extension never hears, and the next Focus edge writes the slots
    /// straight back while the user is looking at an error (Codex, PR #625).
    func testAFailedOptOutIsNotTreatedAsConsentWithdrawn() throws {
        let source = try readAppViewModelSource()
        let setter = try sourceBlock(
            in: source,
            startingAt: "    func setKeepNetworkActivity(",
            endingBefore: "func setKeepLavaGuardProgress(")
        XCTAssertTrue(
            setter.contains("let previous = configuration.keepNetworkActivity"),
            "the prior value must be captured so a failed write can be undone")
        XCTAssertTrue(
            setter.contains("configuration.keepNetworkActivity = previous"),
            "a failed persist must roll the in-memory flag back — app, disk and the extension have "
                + "to tell one story")

        // THE EARLY RETURN IS THE LOAD-BEARING HALF: without it the clears still run on a premise
        // that just failed.
        let rollback = try XCTUnwrap(
            setter.range(of: "configuration.keepNetworkActivity = previous")?.lowerBound)
        // 🔴 THE STATEMENT, NOT THE WORD. Searching for "return" matched the word inside the
        // comment above it, so this assertion passed with the early return deleted — vacuous in
        // exactly the way this PR's siblings were.
        let earlyReturn = try XCTUnwrap(
            setter.range(of: "\n            return\n        }", range: rollback..<setter.endIndex))
        let clear = try XCTUnwrap(
            setter.range(of: "FocusSwitchDiagnostics.clear(in: LavaSecAppGroup.sharedDefaults)")?
                .lowerBound)
        XCTAssertLessThan(
            earlyReturn.lowerBound, clear,
            "the catch must return before the clears, or an opt-out that never persisted still "
                + "erases records the other process is about to rewrite")
    }

    /// The bug report reads the Focus diagnostics THROUGH the consent gate, and purges.
    ///
    /// 🔴 STOPPING THE WRITES WAS NOT ENOUGH. The previous release's writer was unconditional, so a
    /// user who already had Network Activity off carries a record written before the gate existed;
    /// they never toggle the switch again, so the transition-clear never fires, and the legacy
    /// value would ship in the next report despite consent having been withdrawn all along
    /// (Codex, PR #625). Purge-on-read is the shape `refreshNetworkActivityLog` already uses.
    func testTheBugReportReadsFocusDiagnosticsUnderConsent() throws {
        let source = try readAppViewModelSource()
        let gate = try sourceBlock(
            in: source,
            startingAt: "    var focusDiagnosticsUnderConsent:",
            endingBefore: "/// Classifies a failed Focus reconcile apply")
        XCTAssertTrue(
            gate.contains("Self.withFocusDiagnosticsConsent { consented in"),
            "the read must consult consent through the shared resolver")
        XCTAssertTrue(gate.contains("guard consented else {"), "and act on its answer")
        // 🔴 NEVER THE IN-MEMORY COPY. It can be a placeholder — a default `AppConfiguration`
        // left in memory when the real file is locked before first unlock, whose
        // `keepNetworkActivity` is `true` (Codex, PR #625).
        XCTAssertFalse(
            sourceCodeOnly(gate).contains("configuration.keepNetworkActivity"),
            "consent must come from the persisted configuration, not a possibly-placeholder copy")
        XCTAssertTrue(
            gate.contains("FocusSwitchDiagnostics.clear(in: LavaSecAppGroup.sharedDefaults)"),
            "and PURGE the legacy record rather than merely hiding it — an upgrading user who "
                + "never toggles the switch would otherwise keep it on disk forever")
        XCTAssertTrue(gate.contains("return (nil, nil)"), "and surface nothing")

        // THE ONLY READ PATH. If the bundle read the store directly it would bypass the gate, and
        // the purge would never run for the user it exists for.
        XCTAssertTrue(
            source.contains("lastFocusSwitch: focusDiagnosticsUnderConsent.last"),
            "the bundle must read through the gate, not the store")
        XCTAssertTrue(
            source.contains("lastFocusFailure: focusDiagnosticsUnderConsent.failure"),
            "both slots must read through the gate")
    }

    /// "Clear all local logs" reaches the Release-persisted slots without blocking on a Focus switch.
    ///
    /// It already cleared the device debug log and the incident ledger and left these two behind —
    /// the one record that survives into a shipping build, missed by the user's most explicit
    /// erase gesture (MECE panel, PR #625). The generation-advancing clear closes the accepted
    /// PR #626 race without taking the long-lived Focus-switch lock on the main actor.
    func testClearAllLocalLogsErasesTheFocusDiagnostics() throws {
        let source = try readSource(.diagnosticsController)
        let clearAll = try sourceBlock(
            in: source,
            startingAt: "    func clearAllLocalLogs() -> Bool {",
            endingBefore: "    private func")
        XCTAssertTrue(
            clearAll.contains("FocusSwitchDiagnostics.clear(")
                && clearAll.contains("in: LavaSecAppGroup.sharedDefaults")
                && clearAll.contains("LavaSecAppGroup.focusDiagnosticOrderingLockFilename")
                && clearAll.contains("now: { clearedAt }"),
            "the erase-everything gesture must stamp the cut-over and reach the slots that survive into Release")
        // The configuration lock remains the short consent-resolution boundary, but the
        // Focus-switch lock must stay out of this synchronous main-actor clear (PR #626).
        XCTAssertTrue(
            clearAll.contains("FocusSwitchDiagnostics.withResolvedConsent("),
            "the clear must retain the short persisted-consent boundary")
        XCTAssertFalse(
            clearAll.contains("orderedAgainstSwitchLockURL"),
            "the synchronous clear must not wait for the Focus-switch lock")
    }

    /// The Settings row RENDERS a decision it does not make.
    ///
    /// Field report (jimmy, 2026-09-01 travel outage): the row read "Off — VPN chaining stopped
    /// forwarding" while `chainedUpstreamEnabled` was still true, which reads as "Lava turned my
    /// setting off". It never did — `reconcileChainedUpstreamAfterEligibilityChange` clears the
    /// preference only for entitlement/memory ineligibility and documents that surrender must not.
    ///
    /// That was first fixed by editing two string literals, which left the rule as a convention
    /// every future branch had to remember. The decision now lives in `ChainedSurfaceSummary`,
    /// where `settingOff` is reachable from exactly one state and
    /// `ChainedSurfaceStateTests.testTheSummaryNeverContradictsTheUsersSetting` proves it
    /// exhaustively. What is left for a source pin is the part no type can enforce: that this app
    /// surface delegates instead of re-deriving.
    func testTheChainingSummaryDelegatesToTheTestedPolicy() throws {
        let source = try readAppViewModelSource()
        let summary = try sourceBlock(
            in: source,
            startingAt: "    var vpnChainingSummaryText: String {",
            endingBefore: "/// Cable-driven QA setup")
        XCTAssertTrue(
            summary.contains("switch ChainedSurfaceSummary(chainedOperationalState)"),
            "the row must render the policy's answer, not re-derive one from the status fields")
        XCTAssertFalse(
            sourceCodeOnly(summary).contains("configuration."),
            "a second read of the preference here is a second decision that can disagree")
        XCTAssertEqual(
            sourceOccurrenceCount(of: "return \"Off\"", in: summary), 1,
            "exactly one branch — the `.settingOff` arm — may render the disabled token")

        // …and the ONE cheap term stays ahead of the expensive status read, which re-reads the
        // store and hits the Keychain on the main actor during render.
        let state = try sourceBlock(
            in: source,
            startingAt: "    var chainedOperationalState: ChainedOperationalState {",
            endingBefore: "/// One-line summary for the Settings row.")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "guard configuration.hasLavaSecurityPlus else { return .notEntitled }",
                    "chainedOperationalState(from: chainedUpstreamSurfaceStatus)",
                ], in: state),
            "entitlement must settle before the store/Keychain read")
        // 🔴 THE PREFERENCE MAY NOT SHORT-CIRCUIT HERE. `resolve` puts the conditions that disable
        // the toggle above the preference, so answering `.preferenceOff` from `configuration`
        // alone would be a DIFFERENT answer from the policy's — the divergence this consolidation
        // removes, reintroduced in the helper meant to serve it (Codex, PR #637).
        XCTAssertFalse(
            sourceCodeOnly(state).contains("chainedUpstreamEnabled"),
            "the preference cannot be answered without the snapshot the policy reads")
    }

    /// Admission and actionable restrictions share the model's snapshot; ordinary toggle
    /// changes leave the external option explanation untouched.
    func testTheChainingControlKeepsStaticCopyAndSharedAvailability() throws {
        let view = try readSource(.vpnChainingSettingsView)
        let body = try sourceBlock(
            in: view,
            startingAt: "        let status = viewModel.chainedUpstreamSurfaceStatus",
            endingBefore: "\n    private func")
        XCTAssertTrue(
            body.contains("let state = viewModel.chainedOperationalState(from: status)"),
            "the row must resolve the state ONCE, from the snapshot the view already read")
        XCTAssertTrue(
            body.contains("chainingRestriction(status, state: state)"),
            "availability restrictions must render that same resolved state")
        XCTAssertTrue(body.contains("LavaQuietFooter(chainingExplanation)"))
        XCTAssertFalse(body.contains("Route my traffic through this VPN setup"))
        let explanation = try sourceBlock(
            in: view,
            startingAt: "    private var chainingExplanation: String {",
            endingBefore: "    private func chainingRestriction(")
        XCTAssertFalse(sourceCodeOnly(explanation).contains("viewModel."))
        XCTAssertFalse(sourceCodeOnly(explanation).contains("switch"))
        // 🔴 ONE status read per body pass. Each one opens the configuration store and hits the
        // Keychain on the main actor and can wait 250 ms for the lifecycle lock; a second read
        // pays that twice AND reopens the divergence this consolidation closes, because the stores
        // can move between the two (Codex, PR #637).
        XCTAssertEqual(
            sourceOccurrenceCount(of: "viewModel.chainedUpstreamSurfaceStatus", in: body), 1,
            "the toggle and its detail line must render from the same snapshot, read once")
        let detail = try sourceBlock(
            in: view,
            startingAt: "    private func chainingRestriction(",
            endingBefore: "\n    // MARK:")
        XCTAssertTrue(
            detail.contains("switch state {"),
            "the detail line must switch over the shared state")
        // 🔴 THE CONTROL, THE UPGRADE ROUTE AND THE LINE ALL READ THAT ONE STATE. They used to
        // read three sources — the switch and the button from raw `status` fields, the line from
        // the state — and disagreed for a non-Plus account whose device store is unreadable:
        // `ineligibility` is nil there by design, so the button vanished while the line said
        // chaining needs Plus, leaving a dead grey control and no way to buy what it named
        // (Codex, PR #637).
        let rowToggle = try sourceBlock(in: readAppViewModelSource(), startingAt: "func setWireGuardRowEnabled", endingBefore: "func commitWireGuardPage")
        XCTAssertTrue(rowToggle.contains("ChainedSetupPolicy.canEditConfiguration(chainedSurfaceInputs(from: status))"))
        XCTAssertTrue(
            body.contains("if state == .notEntitled {"),
            "the upgrade route must open for the same state the detail line explains")
        XCTAssertFalse(
            sourceCodeOnly(body).contains("status.ineligibility"),
            "no surface in this row may re-derive availability from the raw status fields")
        XCTAssertFalse(
            sourceCodeOnly(detail).contains("status."),
            "reading status fields here reintroduces the second decision table")
        XCTAssertTrue(detail.contains("case .preferenceOff, .ready:"))
        XCTAssertTrue(detail.contains("return nil"))
    }

}
