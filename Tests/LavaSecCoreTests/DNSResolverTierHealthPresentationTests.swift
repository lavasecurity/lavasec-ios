import Foundation
import XCTest
import LavaSecKit
import LavaSecPresentation

final class DNSResolverTierHealthPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTierFailureRemainsVisibleBesideAnotherTiersSuccess() throws {
        let health = TunnelHealthSnapshot(
            startedAt: now.addingTimeInterval(-300), updatedAt: now, isChainedUpstreamActive: true,
            dnsTierHealth: [
                DNSResolverTierHealthSnapshot(tier: .tierZero, resolverKind: .upstream,
                    lastOutcome: .served, attemptCount: 20, servedCount: 20, lastObservedAt: now),
                DNSResolverTierHealthSnapshot(tier: .tierTwo, resolverKind: .device,
                    transport: .deviceDNS, egress: .physical, lastOutcome: .failure,
                    attemptCount: 1, failureCount: 1, consecutiveFailureCount: 1,
                    lastObservedAt: now,
                    recoveryKind: .recaptureDeviceDNS, recoveryStatus: .eligible),
            ])
        let sections = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)
        XCTAssertEqual(sections.map(\.id), ["dns-health-tierZero", "dns-health-tierOne", "dns-health-tierTwo"])
        let first = try XCTUnwrap(sections.first)
        XCTAssertEqual(value("observation", in: first), "Served")
        let last = try XCTUnwrap(sections.last)
        XCTAssertEqual(value("observation", in: last), "Failed")
        XCTAssertEqual(value("failure-streak", in: last), "1")
        XCTAssertEqual(value("recovery", in: last), "Device DNS reconnect eligible")
        XCTAssertEqual(value("observation", in: sections[1]), "No observations yet")
    }

    func testAnotherTiersFreshServiceCannotRefreshOldTierEvidenceOrRepair() {
        let health = TunnelHealthSnapshot(
            startedAt: now.addingTimeInterval(-300), updatedAt: now, isChainedUpstreamActive: true,
            dnsTierHealth: [
                DNSResolverTierHealthSnapshot(tier: .tierZero, resolverKind: .upstream,
                    lastOutcome: .served, attemptCount: 20, servedCount: 20, lastObservedAt: now),
                DNSResolverTierHealthSnapshot(tier: .tierTwo, resolverKind: .device,
                    transport: .deviceDNS, egress: .physical, lastOutcome: .failure,
                    attemptCount: 2, failureCount: 2, consecutiveFailureCount: 2,
                    lastObservedAt: now.addingTimeInterval(-91),
                    recoveryKind: .recaptureDeviceDNS, recoveryStatus: .throttled),
            ])
        let sections = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)
        XCTAssertEqual(value("observation", in: sections[0]), "Served")
        XCTAssertEqual(value("observation", in: sections[2]), "Sample out of date")
        XCTAssertEqual(value("failure-streak", in: sections[2]), "2")
        XCTAssertEqual(value("recovery", in: sections[2]), "Status unavailable")
    }

    func testPendingDeviceConfirmationIsVisibleWithoutClaimingReconnectAdmission() {
        let health = TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-60), updatedAt: now,
            dnsTierHealth: [DNSResolverTierHealthSnapshot(tier: .tierTwo, resolverKind: .device,
                transport: .deviceDNS, egress: .physical, lastOutcome: .failure,
                attemptCount: 1, failureCount: 1, consecutiveFailureCount: 1,
                lastObservedAt: now, recoveryKind: .recaptureDeviceDNS, recoveryStatus: .waiting)])
        let section = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)[2]
        XCTAssertEqual(value("observation", in: section), "Failed")
        XCTAssertEqual(value("failure-streak", in: section), "1")
        XCTAssertEqual(value("recovery", in: section), "Checking Device DNS")
        for kind in [DNSResolverTierHealthSnapshot.RecoveryKind.upstreamSession, .retryFixedEndpoint, .none] {
            XCTAssertEqual(DNSResolverTierHealthPresentation.recoveryLabel(kind: kind, status: .waiting),
                           "Waiting for recovery")
        }
    }

    func testTierEvidenceRequiresItsOwnTimestampInTheCurrentSessionEnvelope() {
        for observedAt in [nil, now.addingTimeInterval(1), now.addingTimeInterval(-61)] {
            let health = TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-60), updatedAt: now,
                dnsTierHealth: [DNSResolverTierHealthSnapshot(tier: .tierOne,
                    lastOutcome: .served, servedCount: 3, lastObservedAt: observedAt)])
            let section = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)[1]
            XCTAssertEqual(value("observation", in: section), "Sample out of date")
            XCTAssertEqual(value("served", in: section), "3")
            XCTAssertEqual(value("recovery", in: section), "Status unavailable")
        }
    }

    func testFixedAndUpstreamRepairsNeverClaimADeviceDNSReconnect() {
        for status in [DNSResolverTierHealthSnapshot.RecoveryStatus.eligible, .retrying, .restarting, .upstreamWaiting] {
            XCTAssertFalse(DNSResolverTierHealthPresentation.recoveryLabel(kind: .retryFixedEndpoint, status: status).contains("Reconnect"))
            XCTAssertFalse(DNSResolverTierHealthPresentation.recoveryLabel(kind: .upstreamSession, status: status).contains("Device DNS"))
        }
        XCTAssertEqual(DNSResolverTierHealthPresentation.recoveryLabel(kind: .retryFixedEndpoint, status: .retrying), "Retrying resolver")
        XCTAssertEqual(DNSResolverTierHealthPresentation.recoveryLabel(kind: .upstreamSession, status: .upstreamWaiting), "Upstream session recovery")
    }

    func testOutOfDateSamplePreservesCountersWithoutClaimingCurrentRepair() throws {
        let snapshot = DNSResolverTierHealthSnapshot(tier: .tierOne,
            lastOutcome: .failure, attemptCount: 4, failureCount: 4,
            lastObservedAt: now.addingTimeInterval(-91),
            recoveryKind: .recaptureDeviceDNS, recoveryStatus: .restarting)
        let health = TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-91), dnsTierHealth: [snapshot])
        let section = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)[1]
        XCTAssertEqual(value("observation", in: section), "Sample out of date")
        XCTAssertEqual(value("attempts", in: section), "4")
        XCTAssertEqual(value("recovery", in: section), "Status unavailable")
    }

    func testStoppedGuardAndAbsentUpstreamDoNotClaimActiveTierHealth() {
        let health = TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-300), updatedAt: now,
            dnsTierHealth: [DNSResolverTierHealthSnapshot(tier: .tierZero,
                lastOutcome: .failure, lastObservedAt: now, recoveryKind: .upstreamSession,
                recoveryStatus: .upstreamWaiting)])
        let stopped = DNSResolverTierHealthPresentation.sections(health: health, isConnected: false, now: now)
        XCTAssertTrue(stopped.allSatisfy { value("observation", in: $0) == "Not connected" })
        let active = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)
        XCTAssertEqual(value("observation", in: active[0]), "Not active")
        XCTAssertEqual(value("recovery", in: active[0]), "Status unavailable")
        XCTAssertEqual(value("observation", in: active[1]), "No observations yet")
    }

    func testOpaqueConfigurationIdentityIsNeverDisplayed() {
        let health = TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-300), updatedAt: now,
            dnsTierHealth: [DNSResolverTierHealthSnapshot(tier: .tierOne,
                configurationIdentity: "opaque-config-do-not-display", resolverKind: .fixed,
                transport: .dnsOverHTTPS, lastOutcome: .served, lastObservedAt: now)])
        let rows = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)[1].rows
        XCTAssertFalse(rows.contains { $0.value.contains("opaque-config-do-not-display") })
        XCTAssertTrue(rows.contains { $0.id == "source" && $0.value == "Selected resolver" })
    }

    func testMixedEndpointEgressDoesNotClaimPhysicalOnlyRouting() {
        let health = TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-300), updatedAt: now,
            dnsTierHealth: [DNSResolverTierHealthSnapshot(tier: .tierOne,
                resolverKind: .device, egress: .mixed, lastOutcome: .failure, lastObservedAt: now,
                recoveryKind: .upstreamSession, recoveryStatus: .upstreamWaiting)])
        let section = DNSResolverTierHealthPresentation.sections(health: health, isConnected: true, now: now)[1]
        XCTAssertEqual(value("egress", in: section), "Mixed routes")
        XCTAssertEqual(value("recovery", in: section), "Upstream session recovery")
    }

    private func value(_ id: String, in section: DNSResolverTierHealthPresentation.Section) -> String? {
        section.rows.first { $0.id == id }?.value
    }
}
