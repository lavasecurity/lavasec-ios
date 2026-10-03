import Foundation
import XCTest

final class DNSResolverTierHealthSourceTests: XCTestCase {
    func testManualTierRepairUsesTheSharedGuardActionAcrossTheExistingBridgeAndHandler() throws {
        let app = try readSource(.appViewModelCore)
        let projection = try sourceBlock(in: app, startingAt: "var guardStatusPresentation:",
                                         endingBefore: "private var guardNetworkUnavailableOverridesNotice:")
        XCTAssertTrue(projection.contains("offersDeviceDNSRecapture: offersManualDeviceDNSTierRecapture"))
        XCTAssertTrue(projection.contains("!profile.includeAllNetworks"))
        XCTAssertTrue(projection.contains("tunnelHealth.networkPathIsSatisfied"))
        XCTAssertTrue(projection.contains("configuration.chainedTierOneFallbackEnabled"))
        XCTAssertTrue(projection.contains("storedChainedRoutingPolicyForEnforcement == .splitTunnel"))
        XCTAssertFalse(projection.contains("#if"), "The Device repair route check must also run in Release.")
        XCTAssertTrue(projection.contains("guardEnabled: userProtectionIntent.isEnabled"))
        XCTAssertTrue(projection.contains("connectedAt: tunnelManager?.connection.connectedDate"))
        XCTAssertTrue(projection.contains("isConnected: vpnStatus == .connected && tunnelManager?.connection.status == .connected"))
        XCTAssertFalse(projection.contains(".needsReconnect"), "Tier repair must not rewrite aggregate health.")
        let action = try readSource(.appViewModelShareableFilters)
        XCTAssertTrue(action.contains("performProtectionPrimaryAction(guardStatusPresentation.primaryAction)"))
        XCTAssertTrue(action.contains("switch capturedAction"))
        XCTAssertTrue(action.contains("case .reconnect: reconnectProtection()"))
        let bridge = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(bridge.contains("\"actionTone\": m.protectionActionTone"))
        XCTAssertTrue(bridge.contains("\"action\": m.protectionButtonTitle.lavaLocalized"))
        XCTAssertTrue(bridge.contains("model.performProtectionPrimaryAction(primaryAction)"))
        XCTAssertTrue(bridge.contains("model.refreshDNSSettingsPresentation()\n            await refreshManagedDNSPatch()"))
    }

    func testAuthorizationPreservesTheTappedRepairAndRejectsNewerOffIntent() throws {
        let bridge = try readSource(.reactNativeAppBridge)
        let action = try sourceBlock(in: bridge, startingAt: "case \"protection.toggle\":",
                                    endingBefore: "case \"protection.pause\":")
        let capture = try XCTUnwrap(action.range(of: "let primaryAction = model.guardStatusPresentation.primaryAction"))
        let authorization = try XCTUnwrap(action.range(of: "try await authorize("))
        let dispatch = try XCTUnwrap(action.range(of: "model.performProtectionPrimaryAction(primaryAction)"))
        XCTAssertLessThan(capture.lowerBound, authorization.lowerBound)
        XCTAssertLessThan(authorization.lowerBound, dispatch.lowerBound)
        XCTAssertTrue(action.contains("model.userProtectionIntent.revision == capturedIntentRevision"))
        XCTAssertTrue(action.contains("!model.userProtectionIntent.allowsExplicitReconnect(reconnectIntent)"))
        XCTAssertFalse(action.contains("model.performProtectionPrimaryAction()"))
        let handler = try readSource(.appViewModelShareableFilters)
        XCTAssertTrue(handler.contains("case .turnOff: turnOffProtection()"))
        XCTAssertTrue(handler.contains("guard guardStatusPresentation.primaryAction == .turnOn else { return }"))
    }

    func testNativeDiagnosticInventoryUsesTypedTierSectionsThroughTheExistingBridge() throws {
        let native = try readSource(.legalVersionSettingsView)
        XCTAssertTrue(native.contains("DNSResolverTierHealthPresentation.sections("))
        XCTAssertTrue(native.contains("HealthRow(id: $0.id, title: $0.title, value: $0.value)"))
        let bridge = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(bridge.contains("VersionDiagnostics.healthSections(for: m, handshake: sample.handshake)"))
        XCTAssertTrue(bridge.contains("\"healthSections\": sections.map"))
    }

    func testDynamicTierEvidenceAndRepairLabelsCoverEveryAppLocale() throws {
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sourceFileURL(.localizableStringsCatalog))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sourceFileURL(.supportedLocalesManifest))) as? [String: Any])
        let locales = Set(try XCTUnwrap(manifest["locales"] as? [String]))
        for key in ["T0 · VPN DNS health", "T1 · Primary DNS health", "T2 · Fallback DNS health",
                    "Resolver source", "DNS route", "Physical network", "Mixed routes", "Replies without service",
                    "Failure streak", "Rejected reply streak", "Device DNS reconnect eligible",
                    "Reconnecting for Device DNS", "Resolver retry eligible", "Retrying resolver",
                    "Upstream session recovery", "Reconnect deferred", "Recovery unavailable",
                    "Checking Device DNS"] {
            let values = try XCTUnwrap(strings[key]?["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(values.keys), locales, key)
        }
    }
}
