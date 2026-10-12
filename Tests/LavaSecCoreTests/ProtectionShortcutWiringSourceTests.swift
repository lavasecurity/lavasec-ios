import XCTest
@testable import LavaSecCore

/// AppIntents and NetworkExtension cannot execute in the macOS package test target.
/// These pins cover only the safety boundaries around the behavior tested in ProtectionStatusTests.
final class ProtectionShortcutWiringSourceTests: XCTestCase {
    func testBackgroundAppGraphDoesNotOwnTheProtectionModel() throws {
        let source = sourceCodeOnly(try readSource(.lavaSecApp))
        let app = try sourceBlock(in: source, startingAt: "struct LavaSecApp: App {",
            endingBefore: "private struct LavaAppWindowRoot: View {")
        XCTAssertFalse(app.contains("@StateObject"))
        XCTAssertFalse(app.contains("LavaProtectionShortcutRuntime.shared"))
        XCTAssertTrue(app.contains("WindowGroup {\n            LavaAppWindowRoot()"))
        let window = try sourceBlock(in: source, startingAt: "private struct LavaAppWindowRoot: View {",
            endingBefore: "private enum LavaLiveDNSSmokeState:")
        XCTAssertTrue(window.contains("@StateObject private var viewModel = LavaProtectionShortcutRuntime.shared.viewModel"))
        XCTAssertTrue(window.contains("@StateObject private var security = LavaProtectionShortcutRuntime.shared.security"))
    }

    func testStatusReaderCannotReachProtectionMutationOrViewModelInitialization() throws {
        let source = sourceCodeOnly(try readSource(.protectionShortcuts))
        let statusIntent = try sourceBlock(in: source, startingAt: "struct GetLavaStatusIntent:",
            endingBefore: "final class LavaProtectionShortcutRuntime")
        let reader = try sourceBlock(in: source, startingAt: "enum LavaProtectionStatusReader",
            endingBefore: "extension ProtectionStatus")
        for block in [statusIntent, reader] {
            for forbidden in ["AppViewModel(", "LavaProtectionShortcutRuntime.shared", "refreshProtectionStatus(",
                              "enableProtection(", "disableProtection(", "LavaProtectionCommandService.perform",
                              "flushDiagnosticsMessage", "startVPNTunnel(", "stopVPNTunnel(", "saveToPreferences("] {
                XCTAssertFalse(block.contains(forbidden), forbidden)
            }
        }
        XCTAssertTrue(reader.contains("loadExistingManager()"))
        XCTAssertTrue(reader.contains("readProtectionStatusMessage"))
        XCTAssertTrue(reader.contains("ChainedStartupFailureMarker.observation("))
        XCTAssertTrue(reader.contains("SharedStateFileReader.read("))
        XCTAssertTrue(reader.contains("AppConfiguration.self, from: configurationURL"))
        XCTAssertTrue(reader.contains("chainedFailure = configuration.chainedUpstreamEnabled"))
        XCTAssertTrue(reader.contains("evidence.status(now: Date(), chainedFailure: chainedFailure)"))
        XCTAssertTrue(reader.contains("evidence.statusPublication"))
        XCTAssertTrue(reader.contains("ProtectionStatusPublicationReader()"))
        XCTAssertTrue(reader.contains("let providerID = evidence.providerLifecycleID"))
        XCTAssertTrue(reader.contains("manager.connection.connectedDate == connectedAt"))
        XCTAssertTrue(reader.contains("connectionProof: proof"))
        XCTAssertFalse(reader.contains("protectionStatusIdentityWork.read()"))
    }

    func testProviderStatusMessageOnlyCopiesCurrentObservations() throws {
        let source = sourceCodeOnly(try readSource(.packetTunnelProviderAppMessaging))
        let read = try sourceBlock(in: source, startingAt: "case LavaSecAppGroup.readProtectionStatusMessage:",
            endingBefore: "case LavaSecAppGroup.chainedHandshakeStatusMessage:")
        for forbidden in ["currentChainedHandshakeState(", "flush", "persist", "resume", "requestSnapshotReload("] {
            XCTAssertFalse(read.contains(forbidden), forbidden)
        }
        XCTAssertTrue(read.contains("snapshotStatusEvidence()"))
        XCTAssertTrue(read.contains("self.health"))
        XCTAssertTrue(read.contains("cachedTemporaryProtectionPauseUntil"))
        XCTAssertTrue(read.contains("sampleProtectionStatusPublication(evidence: evidence)"))
    }

    func testCanonicalPublicationPrecedesForegroundRenderingAndHealthNudges() throws {
        let app = sourceCodeOnly(try readSource(.appViewModelChainedConnectLifecycle))
        let signals = sourceCodeOnly(try readSource(.appViewModelLiveActivity))
        let diagnostics = sourceCodeOnly(try readSource(.packetTunnelProviderDiagnostics))
        let lifecycle = sourceCodeOnly(try readSource(.packetTunnelProviderLifecycle))
        XCTAssertTrue(app.contains("readProtectionStatusPublication()"))
        XCTAssertTrue(app.contains("reader.admit(candidate"))
        XCTAssertTrue(app.contains("publication.remainingLease(clock: clock, connectionProof: providerStatusConnectionProof)"))
        XCTAssertTrue(app.contains("if (providerStatusOwnsPresentation || providerStatusIdentityVerifiedAt != nil)"))
        XCTAssertTrue(app.contains("let admitted = reader.admit(candidate"))
        XCTAssertTrue(app.contains("if admitted { providerStatusOwnsPresentation = true }"))
        XCTAssertTrue(app.contains("let observation = ChainedRuntimeObservation.fromTunnelReply(reply)"))
        XCTAssertTrue(app.contains("if observation == .dnsOnly"))
        XCTAssertTrue(app.contains("observation == .inactive && reply.statusPublication?.status == .unavailable"))
        XCTAssertTrue(app.contains("guard publication.providerLifecycleID == providerID"))
        let bridge = sourceCodeOnly(try readSource(.reactNativeAppBridge))
        XCTAssertTrue(bridge.contains("self?.model.refreshProtectionStatusForForegroundPresentation()"))
        let foreground = try sourceBlock(in: app, startingAt: "func refreshProtectionStatusForForegroundPresentation()",
            endingBefore: "private func logChainedEstablishmentGate(")
        let active = try XCTUnwrap(foreground.range(of: "setChainedObservationActive(true)"))
        let refresh = try XCTUnwrap(foreground.range(of: "refreshProviderStatusPublication(revalidateIdentity: true)"))
        XCTAssertLessThan(active.lowerBound, refresh.lowerBound)
        XCTAssertTrue(app.contains("!admitted, !providerStatusIdentityIsUncertain, next == .unavailable"))
        XCTAssertTrue(app.contains("UIApplication.shared.applicationState != .active"))
        XCTAssertTrue(app.contains("await LavaSecAppGroup.protectionStatusIdentityWork.read()"))
        XCTAssertFalse(app.contains("currentProtectionStatusProviderID()"))
        XCTAssertTrue(app.contains("providerStatusIdentityGeneration == generation"))
        XCTAssertTrue(app.contains("began.isAtOrAfter(requestedAt)"))
        XCTAssertTrue(app.contains("guard case .observed(let id?, let began) = outcome, !id.isEmpty"))
        XCTAssertFalse(app.contains("began.date >= connectedAt"))
        XCTAssertTrue(app.contains("providerStatusConnectionProof = nil"))
        XCTAssertTrue(app.contains("if case .paused? = next { loadTemporaryProtectionPause() }"))
        XCTAssertTrue(signals.contains("func handleTunnelHealthNudge() {\n        refreshProviderStatusPublication()"))
        XCTAssertTrue(diagnostics.contains("SharedStateFileProtection.atomicControlPlaneWritingOptions"))
        XCTAssertTrue(diagnostics.contains("ProtectionStatusPublication.heartbeatSeconds"))
        XCTAssertTrue(diagnostics.contains("guard tunnelLifecycleIsActive, latchedChainedLifecycleEvidenceID != nil else"))
        XCTAssertTrue(diagnostics.contains("refreshProtectionPauseStateOnly(reason: \"status-heartbeat\")"))
        XCTAssertTrue(lifecycle.contains("self?.protectionStatusHeartbeat.assumeIsolated { $0.stop() }"))
        XCTAssertTrue(lifecycle.contains("self.tunnelLifecycleIsActive = false"))
        XCTAssertTrue(lifecycle.contains("self.publishProtectionStatus()"))
    }

    func testPausePresentationAndResumeGuardShareTheAdmittedDeadline() throws {
        let app = sourceCodeOnly(try readSource(.appViewModelCore))
        let pause = try sourceBlock(in: app, startingAt: "var presentedTemporaryProtectionPauseUntil: Date?",
            endingBefore: "var guardDNSFlowStepStatus:")
        XCTAssertTrue(pause.contains("if let status = canonicalProviderStatus"))
        XCTAssertTrue(pause.contains("if case .paused(let until) = status { return until }"))
        XCTAssertTrue(pause.contains("vpnStatus == .connected && presentedTemporaryProtectionPauseUntil != nil"))
        XCTAssertTrue(pause.contains("guard let until = presentedTemporaryProtectionPauseUntil"))
        let commands = sourceCodeOnly(try readSource(.appViewModelProtectionPause))
        XCTAssertTrue(commands.contains("func resumeProtectionNow() {\n        guard isProtectionTemporarilyPaused"))
        XCTAssertTrue(commands.contains("let pauseWasAccepted = vpnStatus == .connected && temporaryProtectionPauseUntil != nil"))
    }

    func testCommandsUseExistingAuthenticationAndLifecycleBoundaries() throws {
        let source = sourceCodeOnly(try readSource(.protectionShortcuts))
        XCTAssertFalse(source.contains("URLRepresentableIntent"))
        XCTAssertFalse(source.contains("requestConfirmation("))
        XCTAssertTrue(source.contains("security.requireFreshAuthentication(for: .protectionControl"))
        XCTAssertTrue(source.contains("security.requireAuthentication(for: .appUnlock"))
        XCTAssertTrue(source.contains("projectionURL: LavaSecAppGroup.securityGateProjectionURL"))
        XCTAssertTrue(source.contains("viewModel.performProtectionShortcut(enabled: enabled)"))
        let lifecycle = sourceCodeOnly(try readSource(.appViewModelProtectionLifecycle))
        XCTAssertTrue(lifecycle.contains("gate: protectionActionOrchestrator"))
        XCTAssertTrue(lifecycle.contains("enableProtection(persistsExplicitIntent: true)"))
        XCTAssertTrue(lifecycle.contains("ProtectionShortcutCoordinator.validateStartResult("))
        XCTAssertTrue(lifecycle.contains("completed: completed, hasError: self.vpnMessageIsError"))
        XCTAssertTrue(lifecycle.contains("disableProtection(persistsExplicitIntent: true)"))
        XCTAssertTrue(lifecycle.contains("LavaProtectionCommandService.perform(.resume)"))
        XCTAssertTrue(lifecycle.contains("withExclusiveProtectionLifecycleMutation"))
        for forbidden in ["startVPNTunnel(", "stopVPNTunnel(", "toggleProtection("] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}
