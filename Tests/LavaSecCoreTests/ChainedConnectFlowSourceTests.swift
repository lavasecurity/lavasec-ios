import XCTest

@testable import LavaSecCore

/// Source-level wiring pins for the reducer-owned chained connection lifecycle. Behavioral state
/// transitions live in ChainedConnectLifecyclePolicyTests; these tests protect the app boundary
/// where NetworkExtension observations, async effects, diagnostics, and published UI meet.
final class ChainedConnectFlowSourceTests: XCTestCase {
    func testUIKitOwnsObservationLifetimeSynchronously() throws {
        let source = try readAppViewModelSource()
        let owner = try sourceBlock(in: source,
            startingAt: "func startObservingChainedApplicationLifecycle()",
            endingBefore: "private func logChainedEstablishmentGate(")
        for notification in ["willResignActiveNotification", "didEnterBackgroundNotification", "willEnterForegroundNotification", "didBecomeActiveNotification"] {
            XCTAssertTrue(owner.contains(notification))
        }
        XCTAssertTrue(owner.contains("MainActor.assumeIsolated"))
        XCTAssertFalse(owner.contains("Task {"), "Cancellation must happen inside the lifecycle callback, not another queued task.")
        XCTAssertTrue(source.contains("if loadVPNState && !headless { startObservingChainedApplicationLifecycle() }"))
        XCTAssertFalse(try readSource(.rootView).contains("setChainedObservationActive"))
        let foreground = try sourceBlock(in: source,
            startingAt: "func setAppForegroundActive(_ active: Bool)",
            endingBefore: "// GUARDED on protected data")
        XCTAssertFalse(foreground.contains("setChainedObservationActive"), "Deferred scene publication must not reactivate observation.")
    }

    func testForegroundEntryPrefetchStagesWithoutPublishingAndActivationAdmitsBeforeExpiry() throws {
        let source = try readAppViewModelSource()
        let begin = try sourceBlock(in: source,
            startingAt: "private func beginChainedForegroundEntryPrefetch()",
            endingBefore: "private func consumeChainedForegroundEntryPrefetch()")
        XCTAssertTrue(begin.contains("queryChainedHandshakeObservation(reloadMissingManager: false)"))
        XCTAssertTrue(begin.contains("chainedForegroundEntryPrefetch.stage("))
        XCTAssertTrue(begin.contains("!Task.isCancelled"))
        XCTAssertTrue(begin.contains("!self.chainedObservationActive"))
        XCTAssertFalse(begin.contains("reduceChainedConnectLifecycleState("))
        XCTAssertFalse(begin.contains("executeChainedConnectLifecycleEffects("))
        let activate = try sourceBlock(in: source, startingAt: "private func setChainedObservationActive(",
            endingBefore: "private func requestForegroundOnDemandRepair()")
        let consume = try XCTUnwrap(activate.range(of: "consumeChainedForegroundEntryPrefetch()"))
        let admit = try XCTUnwrap(activate.range(of: ".observed(connection: connection, observation: candidate.observation, now: candidate.receivedAt)"))
        let fallback = try XCTUnwrap(activate.range(of: ".observationResumed(now:"))
        XCTAssertLessThan(consume.lowerBound, admit.lowerBound)
        XCTAssertLessThan(admit.lowerBound, fallback.lowerBound)
        XCTAssertTrue(activate[admit.upperBound..<fallback.lowerBound].contains("} else {"),
            "Fresh admission substitutes for a missing-observation resume; it must not open another gap")
        XCTAssertFalse(activate.contains("await "), "Activation may never await a hanging provider")
        let consumeOwner = try sourceBlock(in: source,
            startingAt: "private func consumeChainedForegroundEntryPrefetch()",
            endingBefore: "private func cancelChainedForegroundEntryPrefetch()")
        for guardText in ["UIApplication.shared.applicationState == .active", "session.status == .connected",
                          "tunnelManager?.connection === session", "identity == chainedLifecycleMutationIdentity",
                          "identity.protectionIntentRevision == userProtectionIntent.revision",
                          "identity.externalRestartGeneration == restartGeneration",
                          "identity: chainedConnectLifecycleState.foregroundEntryIdentity"] {
            XCTAssertTrue(consumeOwner.contains(guardText), guardText)
        }
        let query = try sourceBlock(in: source,
            startingAt: "func queryChainedHandshakeObservation(reloadMissingManager:",
            endingBefore: "var catalogCacheURL:")
        XCTAssertTrue(query.contains("if reloadMissingManager, tunnelManager == nil"))
        XCTAssertTrue(query.contains("Self.chainedHandshakeQueryTimeout"))
    }

    func testForegroundObservationPausesWithoutDiscardingConnectedEvidence() throws {
        let source = try readAppViewModelSource()
        let suspension = try sourceBlock(in: source, startingAt: "func setChainedObservationActive(", endingBefore: "private func stopChainedLifecycleSampling()")
        XCTAssertTrue(suspension.contains("chainedLifecycleSamplingTask?.cancel()"))
        XCTAssertTrue(suspension.contains("startChainedLifecycleSampling(connection: connection)"))
        XCTAssertFalse(suspension.contains(".statusChanged"), "Visibility is not a tunnel lifecycle event.")
        XCTAssertFalse(suspension.contains("chainedConnectLifecycleState ="))
        let sampling = try sourceBlock(in: source, startingAt: "private func startChainedLifecycleSampling(", endingBefore: "func setChainedObservationActive(")
        let reply = try XCTUnwrap(sampling.range(of: "let result = await self.queryChainedHandshakeObservation()"))
        let cancellation = try XCTUnwrap(sampling.range(of: "try Task.checkCancellation()", range: reply.upperBound..<sampling.endIndex))
        let reduction = try XCTUnwrap(sampling.range(of: "self.reduceChainedConnectLifecycleState(", range: reply.upperBound..<sampling.endIndex))
        XCTAssertLessThan(cancellation.lowerBound, reduction.lowerBound, "Discard an IPC timeout spanning background before reduction.")
        let admission = try XCTUnwrap(sampling.range(of: "self.chainedObservationLifetime.accepts(generation)", range: reply.upperBound..<sampling.endIndex))
        XCTAssertLessThan(admission.lowerBound, reduction.lowerBound)
        XCTAssertTrue(sampling.contains("UIApplication.shared.applicationState == .active"))
    }

    func testEveryStatusObservationReducesAndFreshConnectTransfersUserIntent() throws {
        let source = try readAppViewModelSource()
        let update = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()")

        let captureIndex = try XCTUnwrap(
            update.range(of: "let userInitiated = isFreshConnected && awaitsProtectionOnHaptic")?
                .lowerBound)
        let clearIndex = try XCTUnwrap(
            update.range(of: "awaitsProtectionOnHaptic = false", range: captureIndex..<update.endIndex)?
                .lowerBound)
        let reductionIndex = try XCTUnwrap(
            update.range(of: "reduceChainedConnectLifecycleState(", range: clearIndex..<update.endIndex)?
                .lowerBound)
        XCTAssertLessThan(captureIndex, clearIndex)
        XCTAssertLessThan(clearIndex, reductionIndex)
        XCTAssertTrue(update.contains(".statusChanged("))
        let code = sourceCodeOnly(update)
        XCTAssertFalse(
            code.contains("currentTunnelDataPathMode()"),
            "saved mode cannot select the runtime path for an already-live tunnel")
        XCTAssertTrue(
            code.contains("chainedStartupFailureNotice = Self.chainedStartupFailureMessage.lavaLocalized"),
            "the saved chaining flag may only select the degraded-mode disclosure copy")
    }

    func testExternalRestartPulsesTeardownAroundOnlyTheOutboundStatusReduction() throws {
        let source = try readAppViewModelSource()
        let update = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()")

        XCTAssertTrue(
            update.contains(
                "isRestartInFlight && previousStatus == .connected && currentStatus != .connected"),
            "only the first outbound edge of an intentional external restart is suspended")
        let pulseCondition = try XCTUnwrap(
            update.range(of: "if isIntentionalRestartDeparture {")?.lowerBound)
        let begin = try XCTUnwrap(
            update.range(
                of: "beginProtectionTeardown()",
                range: pulseCondition..<update.endIndex)?.lowerBound)
        let reduction = try XCTUnwrap(
            update.range(
                of: "let effects = reduceChainedConnectLifecycleState(",
                range: begin..<update.endIndex)?.lowerBound)
        let execution = try XCTUnwrap(
            update.range(
                of: "executeChainedConnectLifecycleEffects(effects)",
                range: reduction..<update.endIndex)?.lowerBound)
        let end = try XCTUnwrap(
            update.range(
                of: "endProtectionTeardown()",
                range: execution..<update.endIndex)?.lowerBound)

        XCTAssertLessThan(pulseCondition, begin)
        XCTAssertLessThan(begin, reduction)
        XCTAssertLessThan(reduction, execution)
        XCTAssertLessThan(execution, end)
    }

    func testPersistentSamplingIsImmediateAndUsesClaimSpecificThrowingSleeps() throws {
        let source = try readAppViewModelSource()
        let sampling = try sourceBlock(
            in: source,
            startingAt: "private func startChainedLifecycleSampling(connection: UInt64)",
            endingBefore: "private func stopChainedLifecycleSampling()")

        let queryIndex = try XCTUnwrap(
            sampling.range(of: "await self.queryChainedHandshakeObservation()")?.lowerBound)
        let sleepIndex = try XCTUnwrap(
            sampling.range(of: "try await Task.sleep(nanoseconds: interval)")?.lowerBound)
        let diagnosticsIndex = try XCTUnwrap(
            sampling.range(of: "self.recordChainedEstablishmentPoll(observation: observation)")?
                .lowerBound)
        let cancellationIndex = try XCTUnwrap(
            sampling.range(
                of: "try Task.checkCancellation()",
                range: queryIndex..<diagnosticsIndex)?.lowerBound)
        let reductionIndex = try XCTUnwrap(
            sampling.range(of: "self.reduceChainedConnectLifecycleState(")?.lowerBound)
        XCTAssertLessThan(queryIndex, sleepIndex, "the first sample must be immediate")
        XCTAssertLessThan(queryIndex, cancellationIndex)
        XCTAssertLessThan(
            cancellationIndex,
            diagnosticsIndex,
            "a reply for a superseded connection cannot increment the replacement's diagnostics")
        XCTAssertLessThan(
            diagnosticsIndex,
            reductionIndex,
            "the resolving poll must be counted before resolution clears diagnostics")
        XCTAssertTrue(sampling.contains("ChainedRuntimeObservation.fromTunnelReply(reply)"))
        XCTAssertTrue(sampling.contains(".observed("))
        XCTAssertTrue(sampling.contains("connection: connection"))
        XCTAssertTrue(sampling.contains("case .establishing, .checking, .unconfirmed:"))
        XCTAssertTrue(sampling.contains("Self.chainedEstablishmentPollInterval"))
        XCTAssertTrue(sampling.contains("case .confirmed:"))
        XCTAssertTrue(sampling.contains("Self.chainedMonitoringPollInterval"))
        XCTAssertFalse(
            sampling.contains("try? await Task.sleep"),
            "cancellation must exit through throwing sleep instead of spinning another poll")
    }

    func testReducerSingleSourcesEvidenceLimitsAndClampsCounterSubtraction() throws {
        let policy = try readSource(.chainedConnectLifecyclePolicy)
        XCTAssertTrue(
            policy.contains("ChainedEstablishmentPolicy.defaultTimeoutSeconds"),
            "the reducer timeout must remain the establishment policy's public limit")
        XCTAssertTrue(
            policy.contains("ChainedEstablishmentPolicy.forwardingConfirmedByteThreshold"),
            "the reducer must not duplicate the forwarding threshold as a literal")

        let session = try sourceBlock(
            in: policy,
            startingAt: "private static func observeSession(",
            endingBefore: "private static func restartEstablishment(")
        let clampIndex = try XCTUnwrap(
            session.range(of: "session.forwardedBytes >= evidence.baselineBytes")?.lowerBound)
        let subtractionIndex = try XCTUnwrap(
            session.range(of: "session.forwardedBytes - evidence.baselineBytes")?.lowerBound)
        XCTAssertLessThan(
            clampIndex,
            subtractionIndex,
            "a regressed cumulative counter must clamp before unsigned subtraction")
    }

    func testPublishedLifecycleSurfacesAndNoticeAreReducerProjections() throws {
        let source = try readAppViewModelSource()
        let projection = try sourceBlock(
            in: source,
            startingAt: "private func projectChainedConnectLifecycleState()",
            endingBefore: "func reduceChainedConnectLifecycleState(")

        XCTAssertTrue(projection.contains("chainedConnectLifecycleState.projection"))
        XCTAssertTrue(projection.contains("chainedProjection = next"))
        XCTAssertTrue(source.contains("@Published var chainedProjection"))
        XCTAssertFalse(source.contains("@Published var chainedSetupReady"))
        XCTAssertFalse(
            projection.contains("vpnMessage"),
            "lifecycle projection owns a separate notice lane")

        let selection = try sourceBlock(
            in: source,
            startingAt: "private var guardPanelMessageSelection: (message: String, isError: Bool, isChainedFailureMarker: Bool)? {",
            endingBefore: "var guardPanelMessage: String? {")
        XCTAssertTrue(selection.contains("GuardStatusMessagePolicy.select("))
        XCTAssertTrue(selection.contains("errorMessage: vpnMessageIsError ? vpnMessage : nil"))
        XCTAssertTrue(selection.contains("lifecycleNotice: chainedLifecycleNotice"))
        XCTAssertTrue(selection.contains("settingsApplyError: applyError"))
        XCTAssertTrue(selection.contains("setupIssue: chainedConfigurationStartIssue?.message.lavaLocalized"))
        XCTAssertTrue(selection.contains("!isVPNConfigurationInstalled && vpnMessage == Self.vpnPermissionPromptMessage"))

    }

    func testProviderInactiveRemainsConservativeUntilOuterStatusStopsSampling() throws {
        let policy = try readSource(.chainedConnectLifecyclePolicy)
        let observation = try sourceBlock(
            in: policy,
            startingAt: "private static func reduceObservation(",
            endingBefore: "private static func confirmDNSOnly(")
        XCTAssertTrue(observation.contains("case .chained(session: nil)?, .inactive?:"))
        XCTAssertTrue(observation.contains("return observeMissingEvidence("))

        let status = try sourceBlock(
            in: policy,
            startingAt: "private static func reduceStatus(",
            endingBefore: "private static func beginConnection(")
        XCTAssertTrue(status.contains("if previousStatus == .connected"))
        XCTAssertTrue(status.contains("effects.append(.stopSampling)"))

        let source = try readAppViewModelSource()
        let stop = try sourceBlock(
            in: source,
            startingAt: "private func stopChainedLifecycleSampling()",
            endingBefore: "func beginChainedEstablishmentDiagnostics()")
        XCTAssertFalse(
            stop.contains("logChainedEstablishmentGate"),
            "provider inactivity and teardown can pause sampling without cancelling diagnostics")
    }

    func testInitialResolutionOwnsHapticReviewAndLateMonitoringStaysSilent() throws {
        let source = try readAppViewModelSource()
        let executor = try sourceBlock(
            in: source,
            startingAt: "func executeChainedConnectLifecycleEffects(",
            endingBefore: "private func startChainedLifecycleSampling(connection: UInt64)")
        XCTAssertTrue(executor.contains("for effect in effects"))
        XCTAssertTrue(executor.contains("case let .resolveInitialClaim("))
        XCTAssertTrue(executor.contains("connection: connection"))
        XCTAssertTrue(executor.contains("receivedByteDelta"))
        XCTAssertTrue(executor.contains("resolveInitialChainedClaim("))

        let resolution = try sourceBlock(
            in: source,
            startingAt: "private func resolveInitialChainedClaim(",
            endingBefore: "private func isCurrentChainedLifecycleMutation(")
        XCTAssertTrue(resolution.contains("guard confirmed || setupReady,"))
        XCTAssertTrue(resolution.contains("userInitiated,"))
        XCTAssertTrue(resolution.contains("identity.connection == connection"))
        XCTAssertTrue(resolution.contains("withProtectionLifecycleDescendantMutation("))
        XCTAssertTrue(resolution.contains("capturedGeneration: externalRestartGeneration"))
        XCTAssertTrue(resolution.contains("self.isCurrentChainedLifecycleMutation(identity)"))
        XCTAssertTrue(resolution.contains("ChainedConnectLifecyclePolicy.successFeedbackDisposition("))
        XCTAssertTrue(resolution.contains("ProtectionHapticFeedback.play(.protectionOnSucceeded)"))
        XCTAssertTrue(resolution.contains("recordUserInitiatedProtectionOnForReview()"))
        XCTAssertTrue(resolution.contains("receivedByteDelta: receivedByteDelta"))

        let sampling = try sourceBlock(
            in: source,
            startingAt: "private func startChainedLifecycleSampling(connection: UInt64)",
            endingBefore: "private func stopChainedLifecycleSampling()")
        XCTAssertFalse(sampling.contains("ProtectionHapticFeedback"))
        XCTAssertFalse(sampling.contains("recordUserInitiatedProtectionOnForReview"))
    }

    func testDiagnosticsBeginResolveAndCancelAtConnectionBoundaries() throws {
        let source = try readAppViewModelSource()
        let update = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()")
        XCTAssertTrue(update.contains("if isFreshConnected {"))
        XCTAssertTrue(update.contains("beginChainedEstablishmentDiagnostics()"))
        XCTAssertTrue(update.contains("previousStatus == .connected, currentStatus != .connected"))
        XCTAssertTrue(update.contains("cancelChainedEstablishmentDiagnostics()"))

        let resolution = try sourceBlock(
            in: source,
            startingAt: "private func resolveInitialChainedClaim(",
            endingBefore: "private func isCurrentChainedLifecycleMutation(")
        XCTAssertTrue(resolution.contains("confirmed: confirmed"))
        XCTAssertTrue(resolution.contains("receivedByteDelta: receivedByteDelta"))

        let diagnosticResolution = try sourceBlock(
            in: source,
            startingAt: "private func resolveChainedEstablishmentDiagnostics(",
            endingBefore: "func cancelChainedEstablishmentDiagnostics()")
        XCTAssertTrue(diagnosticResolution.contains("receivedDelta: receivedByteDelta"))
        XCTAssertFalse(
            diagnosticResolution.contains("receivedDelta: nil"),
            "confirmed and unconfirmed initial resolutions retain their authoritative byte delta")

        let teardown = try sourceBlock(
            in: source,
            startingAt: "func beginProtectionTeardown()",
            endingBefore: "func endProtectionTeardown()")
        XCTAssertFalse(
            teardown.contains("cancelChainedEstablishmentDiagnostics"),
            "fallible teardown suspension retains initial-resolution diagnostics")
    }

    func testEstablishingAndUnconfirmedProjectionsDriveEveryProtectionSurface() throws {
        let source = try readAppViewModelSource()
        XCTAssertTrue(source.contains("var chainedConnectEstablishing: Bool { chainedProjection.claim == .establishing }"))
        XCTAssertTrue(source.contains("var chainedForwardingUnconfirmed: Bool { chainedProjection.claim == .unconfirmed }"))

        let projection = try sourceBlock(in: source, startingAt: "var protectionStatus: ProtectionStatus {",
            endingBefore: "var protectionButtonTitle: String {")
        XCTAssertTrue(projection.contains("ProtectionStatus.resolve("))
        XCTAssertTrue(projection.contains("chainedEstablishing: chainedConnectEstablishing"))
        XCTAssertTrue(projection.contains("forwardingUnconfirmed: chainedForwardingUnconfirmed"))
        XCTAssertTrue(projection.contains("guardStatusPresentation.title"))
        XCTAssertTrue(projection.contains("switch protectionStatus {"))

        XCTAssertTrue(source.contains("var protectionSymbolName: String {\n        switch protectionStatus {"))
        XCTAssertTrue(source.contains("var protectionTintRole: ProtectionTintRole {\n        guardStatusPresentation.tintRole"))
    }

    func testTheUnconfirmedSurfaceYieldsToARealConnectivityReport() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "private var showsChainedForwardingUnconfirmed: Bool {",
            endingBefore: "var protectionTitle: String {")
        XCTAssertTrue(block.contains("severity.yieldsToUnconfirmedChainedForwarding"))
        XCTAssertTrue(block.contains("guard vpnStatus == .connected else { return false }"))
    }

    func testLegacyGateAndVanishLatchStayRemoved() throws {
        let code = sourceCodeOnly(try readAppViewModelSource())
        for removed in [
            "pendingChainedVanishNotice",
            "chainedEstablishmentTask",
            "beginChainedEstablishmentGate",
            "cancelChainedEstablishmentGate",
            "confirmChainedEstablishment",
            "resolveChainedForwardingUnconfirmed",
            "promoteChainedForwardingConfirmed",
            "armConnectOnDemandForChainedConnection",
        ] {
            XCTAssertFalse(code.contains(removed), "\(removed) duplicates reducer-owned lifecycle state")
        }
    }
}
