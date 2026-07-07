import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class TunnelHealthSnapshotTests: XCTestCase {
    func testDecodingOldHealthDefaultsResolverTransportToPlainDNS() throws {
        let data = Data("""
        {
          "startedAt": "2026-05-17T00:00:00Z",
          "updatedAt": "2026-05-17T00:00:00Z",
          "networkKind": "wifi",
          "cacheHitCount": 0,
          "cacheMissCount": 0,
          "coalescedQueryCount": 0,
          "upstreamSuccessCount": 0,
          "upstreamFailureCount": 0,
          "upstreamTimeoutCount": 0,
          "udpTruncatedResponseCount": 0,
          "tcpFallbackAttemptCount": 0,
          "tcpFallbackSuccessCount": 0,
          "resolverAttemptCounts": {},
          "resolverSuccessCounts": {},
          "resolverFailureCounts": {}
        }
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(snapshot.lastResolverTransport, .plainDNS)
        XCTAssertEqual(snapshot.dohHTTPFailureCount, 0)
        XCTAssertNil(snapshot.lastDoHHTTPVersion)
        XCTAssertEqual(snapshot.deviceDNSFallbackAttemptCount, 0)
        XCTAssertEqual(snapshot.deviceDNSFallbackSuccessCount, 0)
        XCTAssertEqual(snapshot.deviceDNSUnavailableCount, 0)
        XCTAssertTrue(snapshot.networkPathIsSatisfied)
        XCTAssertNil(snapshot.lastDNSSmokeProbeAt)
        XCTAssertNil(snapshot.lastDNSSmokeProbeSucceeded)
        XCTAssertEqual(snapshot.dnsSmokeProbeSuccessCount, 0)
        XCTAssertEqual(snapshot.dnsSmokeProbeFailureCount, 0)
        XCTAssertEqual(snapshot.consecutiveDNSSmokeProbeFailureCount, 0)
        XCTAssertFalse(snapshot.deviceDNSFallbackModeActive)
        XCTAssertNil(snapshot.lastDeviceDNSFallbackActivatedAt)
        XCTAssertEqual(snapshot.deviceDNSFallbackActivationCount, 0)
        XCTAssertEqual(snapshot.consecutiveUpstreamFailureCount, 0)
    }

    func testHealthRoundTripPreservesResolverTransportAndDoHFailures() throws {
        let snapshot = TunnelHealthSnapshot(
            upstreamFailureCount: 3,
            consecutiveUpstreamFailureCount: 3,
            lastResolverTransport: .dnsOverHTTPS,
            dohHTTPFailureCount: 2,
            lastDoHHTTPVersion: "h3",
            deviceDNSFallbackAttemptCount: 3,
            deviceDNSFallbackSuccessCount: 2,
            deviceDNSUnavailableCount: 1,
            networkPathIsSatisfied: false,
            lastDNSSmokeProbeAt: Date(timeIntervalSinceReferenceDate: 800_720_010),
            lastDNSSmokeProbeSucceeded: false,
            dnsSmokeProbeSuccessCount: 5,
            dnsSmokeProbeFailureCount: 6,
            consecutiveDNSSmokeProbeFailureCount: 4,
            deviceDNSFallbackModeActive: true,
            lastDeviceDNSFallbackActivatedAt: Date(timeIntervalSinceReferenceDate: 800_720_020),
            deviceDNSFallbackActivationCount: 7
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.lastResolverTransport, .dnsOverHTTPS)
        XCTAssertEqual(decoded.dohHTTPFailureCount, 2)
        XCTAssertEqual(decoded.lastDoHHTTPVersion, "h3")
        XCTAssertEqual(decoded.deviceDNSFallbackAttemptCount, 3)
        XCTAssertEqual(decoded.deviceDNSFallbackSuccessCount, 2)
        XCTAssertEqual(decoded.deviceDNSUnavailableCount, 1)
        XCTAssertFalse(decoded.networkPathIsSatisfied)
        XCTAssertEqual(decoded.lastDNSSmokeProbeAt, Date(timeIntervalSinceReferenceDate: 800_720_010))
        XCTAssertEqual(decoded.lastDNSSmokeProbeSucceeded, false)
        XCTAssertEqual(decoded.dnsSmokeProbeSuccessCount, 5)
        XCTAssertEqual(decoded.dnsSmokeProbeFailureCount, 6)
        XCTAssertEqual(decoded.consecutiveDNSSmokeProbeFailureCount, 4)
        XCTAssertTrue(decoded.deviceDNSFallbackModeActive)
        XCTAssertEqual(decoded.lastDeviceDNSFallbackActivatedAt, Date(timeIntervalSinceReferenceDate: 800_720_020))
        XCTAssertEqual(decoded.deviceDNSFallbackActivationCount, 7)
        XCTAssertEqual(decoded.consecutiveUpstreamFailureCount, 3)
    }

    func testHealthRoundTripPreservesDoTResolverTransport() throws {
        let snapshot = TunnelHealthSnapshot(lastResolverTransport: .dnsOverTLS)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.lastResolverTransport, .dnsOverTLS)
    }

    func testDecodingOldHealthDefaultsNetworkRecoveryFields() throws {
        let data = Data("""
        {
          "startedAt": "2026-05-17T00:00:00Z",
          "updatedAt": "2026-05-17T00:00:00Z",
          "networkKind": "wifi"
        }
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertNil(snapshot.lastNetworkChangeAt)
        XCTAssertNil(snapshot.lastResolverRuntimeResetAt)
        XCTAssertNil(snapshot.lastResolverRuntimeResetReason)
        XCTAssertNil(snapshot.lastUpstreamSuccessAt)
        XCTAssertNil(snapshot.lastUpstreamFailureAt)
        XCTAssertEqual(snapshot.networkChangeCount, 0)
        XCTAssertEqual(snapshot.resolverRuntimeResetCount, 0)
        XCTAssertEqual(snapshot.consecutiveUpstreamFailureCount, 0)
        XCTAssertEqual(snapshot.consecutiveDNSSmokeProbeFailureCount, 0)
        XCTAssertEqual(snapshot.consecutiveRejectedSmokeResponseCount, 0)
        XCTAssertNil(snapshot.rejectedSmokeResponseResolverIdentity)
        XCTAssertEqual(snapshot.rejectedSmokeResponseRescopeCount, 0)
        XCTAssertNil(snapshot.lastUpstreamDurationMilliseconds)
        XCTAssertEqual(snapshot.slowUpstreamResponseCount, 0)
        XCTAssertEqual(snapshot.consecutiveSlowUpstreamResponseCount, 0)
        XCTAssertNil(snapshot.lastSlowUpstreamResponseAt)
        XCTAssertNil(snapshot.lastNetworkSettingsReapplyFailureAt)
        XCTAssertNil(snapshot.lastNetworkSettingsReapplyFailureReason)
        XCTAssertEqual(snapshot.networkSettingsReapplyFailureCount, 0)
        XCTAssertEqual(snapshot.failClosedServedQueryCount, 0)
        XCTAssertNil(snapshot.lastFailClosedAt)
        XCTAssertNil(snapshot.lastFailClosedReason)
    }

    func testHealthRoundTripPreservesNetworkRecoveryFields() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let snapshot = TunnelHealthSnapshot(
            networkKind: .cellular,
            upstreamFailureCount: 4,
            consecutiveUpstreamFailureCount: 4,
            lastNetworkChangeAt: now,
            networkChangeCount: 2,
            lastResolverRuntimeResetAt: now.addingTimeInterval(1),
            lastResolverRuntimeResetReason: "network-path-changed",
            resolverRuntimeResetCount: 3,
            lastUpstreamSuccessAt: now.addingTimeInterval(2),
            lastUpstreamFailureAt: now.addingTimeInterval(3)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.networkKind, .cellular)
        XCTAssertEqual(decoded.lastNetworkChangeAt, now)
        XCTAssertEqual(decoded.networkChangeCount, 2)
        XCTAssertEqual(decoded.lastResolverRuntimeResetAt, now.addingTimeInterval(1))
        XCTAssertEqual(decoded.lastResolverRuntimeResetReason, "network-path-changed")
        XCTAssertEqual(decoded.resolverRuntimeResetCount, 3)
        XCTAssertEqual(decoded.lastUpstreamSuccessAt, now.addingTimeInterval(2))
        XCTAssertEqual(decoded.lastUpstreamFailureAt, now.addingTimeInterval(3))
        XCTAssertEqual(decoded.consecutiveUpstreamFailureCount, 4)
    }

    func testHealthRoundTripPreservesSlowResolverFields() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let snapshot = TunnelHealthSnapshot(
            lastUpstreamDurationMilliseconds: 3_400,
            slowUpstreamResponseCount: 5,
            consecutiveSlowUpstreamResponseCount: 3,
            lastSlowUpstreamResponseAt: now
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.lastUpstreamDurationMilliseconds, 3_400)
        XCTAssertEqual(decoded.slowUpstreamResponseCount, 5)
        XCTAssertEqual(decoded.consecutiveSlowUpstreamResponseCount, 3)
        XCTAssertEqual(decoded.lastSlowUpstreamResponseAt, now)
    }

    func testHealthRoundTripPreservesNetworkSettingsFailureFields() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let snapshot = TunnelHealthSnapshot(
            lastNetworkSettingsReapplyFailureAt: now,
            lastNetworkSettingsReapplyFailureReason: "network-path-changed: failed",
            networkSettingsReapplyFailureCount: 2
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.lastNetworkSettingsReapplyFailureAt, now)
        XCTAssertEqual(decoded.lastNetworkSettingsReapplyFailureReason, "network-path-changed: failed")
        XCTAssertEqual(decoded.networkSettingsReapplyFailureCount, 2)
    }

    func testHealthRoundTripPreservesRejectedSmokeResponseFields() throws {
        let snapshot = TunnelHealthSnapshot(
            lastFailureReason: "rejected-response",
            consecutiveRejectedSmokeResponseCount: 3,
            rejectedSmokeResponseResolverIdentity: "device:220.159.212.200,220.159.212.201",
            rejectedSmokeResponseRescopeCount: 2
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.consecutiveRejectedSmokeResponseCount, 3)
        XCTAssertEqual(
            decoded.rejectedSmokeResponseResolverIdentity,
            "device:220.159.212.200,220.159.212.201"
        )
        XCTAssertEqual(decoded.rejectedSmokeResponseRescopeCount, 2)
    }

    func testHealthRoundTripPreservesFailClosedTrace() throws {
        let failClosedAt = Date(timeIntervalSinceReferenceDate: 800_800_000)
        let snapshot = TunnelHealthSnapshot(
            failClosedServedQueryCount: 42,
            lastFailClosedAt: failClosedAt,
            lastFailClosedReason: "snapshot-unavailable"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.failClosedServedQueryCount, 42)
        XCTAssertEqual(decoded.lastFailClosedAt, failClosedAt)
        XCTAssertEqual(decoded.lastFailClosedReason, "snapshot-unavailable")
    }
}
