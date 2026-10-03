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
