import Foundation
import XCTest
import LavaSecKit

final class DNSResolverTierHealthSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func deferredDevice(tier: DNSResolverTier = .tierTwo) -> DNSResolverTierHealthSnapshot {
        DNSResolverTierHealthSnapshot(
            tier: tier, configurationIdentity: "opaque-selection", resolverKind: .device,
            transport: .deviceDNS, egress: .physical, lastOutcome: .failure,
            attemptCount: 1, failureCount: 1, consecutiveFailureCount: 1,
            lastObservedAt: now.addingTimeInterval(-5), lastFailureReason: "timeout",
            recoveryKind: .recaptureDeviceDNS, recoveryStatus: .throttled)
    }

    private func offersRecapture(
        _ tier: DNSResolverTierHealthSnapshot,
        configuration: AppConfiguration = AppConfiguration(protectionEnabled: true),
        healthUpdatedAt: Date? = nil, connectedAt: Date? = nil,
        isConnected: Bool = true, guardEnabled: Bool = true,
        physicalEgressPermitted: Bool = true
    ) -> Bool {
        tier.permitsManualDeviceDNSRecapture(
            in: configuration, healthUpdatedAt: healthUpdatedAt ?? now,
            connectedAt: connectedAt ?? now.addingTimeInterval(-60),
            isConnected: isConnected, guardEnabled: guardEnabled,
            physicalEgressPermitted: physicalEgressPermitted, now: now)
    }

    func testManualRecaptureRequiresCurrentDeferredDeviceEvidenceAndGuardIntent() {
        let tier = deferredDevice()
        XCTAssertTrue(offersRecapture(tier))
        XCTAssertFalse(offersRecapture(tier, isConnected: false))
        XCTAssertFalse(offersRecapture(tier, guardEnabled: false))
        XCTAssertFalse(offersRecapture(tier, configuration: AppConfiguration(protectionEnabled: false)))
        XCTAssertFalse(offersRecapture(tier, physicalEgressPermitted: false),
                       "Full, strict and unknown routing profiles cannot offer physical recapture.")
    }

    func testManualRecaptureRejectsStaleFutureAndPreconnectionSamples() {
        var tier = deferredDevice()
        XCTAssertFalse(offersRecapture(tier, healthUpdatedAt: now.addingTimeInterval(-91)))
        XCTAssertFalse(offersRecapture(tier, healthUpdatedAt: now.addingTimeInterval(1)))
        XCTAssertFalse(offersRecapture(tier, connectedAt: now.addingTimeInterval(-1)))
        tier.lastObservedAt = now.addingTimeInterval(-90)
        XCTAssertTrue(offersRecapture(tier, connectedAt: now.addingTimeInterval(-600)))
        tier.lastObservedAt = now.addingTimeInterval(-91)
        XCTAssertFalse(offersRecapture(tier, connectedAt: now.addingTimeInterval(-600)),
                       "Freshness must reject old evidence even when it belongs to this connection.")
        tier.lastObservedAt = now.addingTimeInterval(1)
        XCTAssertFalse(offersRecapture(tier))
        tier.lastObservedAt = nil
        XCTAssertFalse(offersRecapture(tier))
        tier = deferredDevice()
        tier.configurationIdentity = nil
        XCTAssertFalse(offersRecapture(tier))
        tier.configurationIdentity = ""
        XCTAssertFalse(offersRecapture(tier))
        XCTAssertFalse(tier.permitsManualDeviceDNSRecapture(
            in: AppConfiguration(protectionEnabled: true), healthUpdatedAt: now,
            connectedAt: nil, isConnected: true, guardEnabled: true,
            physicalEgressPermitted: true, now: now))
    }

    func testManualRecaptureNeverOffersFixedUpstreamRepliesOrUnadmittedRepair() {
        for kind in [DNSResolverTierHealthSnapshot.ResolverKind.fixed, .upstream] {
            var tier = deferredDevice(); tier.resolverKind = kind
            XCTAssertFalse(offersRecapture(tier))
        }
        for route in [DNSResolverTierHealthSnapshot.Egress.tunnel, .mixed] {
            var tier = deferredDevice(); tier.egress = route
            XCTAssertFalse(offersRecapture(tier))
        }
        for outcome in [DNSResolverTierHealthSnapshot.Outcome.served, .answered, .notAttempted] {
            var tier = deferredDevice(); tier.lastOutcome = outcome
            XCTAssertFalse(offersRecapture(tier))
        }
        for status in [DNSResolverTierHealthSnapshot.RecoveryStatus.notNeeded, .waiting, .eligible,
                       .retrying, .upstreamWaiting, .restarting, .unavailable] {
            var tier = deferredDevice(); tier.recoveryStatus = status
            XCTAssertFalse(offersRecapture(tier))
        }
        var tier = deferredDevice(); tier.recoveryKind = .retryFixedEndpoint
        XCTAssertFalse(offersRecapture(tier))
        tier = deferredDevice(); tier.transport = .dnsOverHTTPS
        XCTAssertFalse(offersRecapture(tier))
        XCTAssertFalse(offersRecapture(deferredDevice(tier: .tierZero)))
    }

    func testManualRecaptureMatchesOnlyTheCurrentEnabledTierSelection() throws {
        var configuration = AppConfiguration(protectionEnabled: true)
        XCTAssertTrue(offersRecapture(deferredDevice(), configuration: configuration))
        XCTAssertFalse(offersRecapture(deferredDevice(tier: .tierOne), configuration: configuration))
        try configuration.applyDNSResolutionSelections([
            .init(id: DNSResolverPreset.device.id), .init(id: DNSResolverPreset.cloudflareDoH.id)
        ], allowsCustom: false)
        XCTAssertTrue(offersRecapture(deferredDevice(tier: .tierOne), configuration: configuration))
        XCTAssertFalse(offersRecapture(deferredDevice(), configuration: configuration))
        try configuration.setDNSResolutionEnabled(false, index: 0)
        XCTAssertFalse(offersRecapture(deferredDevice(tier: .tierOne), configuration: configuration))
        try configuration.applyDNSResolutionSelections([
            .init(id: DNSResolverPreset.cloudflareDoH.id, isEnabled: false),
            .init(id: DNSResolverPreset.device.id)
        ], allowsCustom: false)
        XCTAssertFalse(offersRecapture(deferredDevice(tier: .tierOne), configuration: configuration))
        XCTAssertTrue(offersRecapture(deferredDevice(), configuration: configuration),
                      "An active Device DNS row keeps T2 when the saved T1 row is inactive.")
    }

    func testOlderTunnelHealthPayloadHasNoFabricatedTierEvidence() throws {
        let data = try JSONEncoder().encode(TunnelHealthSnapshot())
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "dnsTierHealth")
        let oldData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: oldData)
        XCTAssertEqual(decoded.dnsTierHealth, [])
    }

    func testTierEvidenceAndRepairAdmissionSurviveTunnelHealthRoundTrip() throws {
        let tier = DNSResolverTierHealthSnapshot(
            tier: .tierTwo, configurationIdentity: "opaque-selection-123",
            resolverKind: .device, transport: .deviceDNS, egress: .physical,
            lastOutcome: .failure, attemptCount: 5, servedCount: 2, answeredCount: 1,
            failureCount: 2, notAttemptedCount: 3, consecutiveFailureCount: 2,
            consecutiveRejectedResponseCount: 1,
            lastObservedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastFailureReason: "timeout", recoveryKind: .recaptureDeviceDNS,
            recoveryStatus: .throttled)
        let snapshot = TunnelHealthSnapshot(dnsTierHealth: [tier])
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.dnsTierHealth, [tier])
        XCTAssertEqual(snapshot.redactingChainedFallbackAddresses().dnsTierHealth, [tier],
                       "Tier counters and opaque repair evidence must survive diagnostic redaction.")
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("resolverAddresses"))
        XCTAssertFalse(json.contains("queriedName"))
        XCTAssertFalse(json.contains("ssid"))
    }
}
