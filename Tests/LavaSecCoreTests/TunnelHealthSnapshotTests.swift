import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class TunnelHealthSnapshotTests: XCTestCase {
    // MARK: - Locked-boot window evidence (INV-PERSIST-2 / the reboot QA release gate)

    func testLockedBootServeBucketsRealClassificationsApartFromFailClosed() {
        var snapshot = TunnelHealthSnapshot()
        snapshot.recordLockedBootServe(action: .block, reason: .blocklist)
        snapshot.recordLockedBootServe(action: .block, reason: .threatGuardrail)
        snapshot.recordLockedBootServe(action: .allow, reason: .defaultAllow)
        snapshot.recordLockedBootServe(action: .allow, reason: .pausedAllow)
        // A fail-closed serve arrives as action == .block but must NEVER count as a
        // blocklist match (the #164 honesty rule) — it buckets into its own counter, so
        // the gate's "blocked ≥ 1 pre-unlock" evidence can only come from real matches.
        snapshot.recordLockedBootServe(action: .block, reason: .protectionUnavailable)

        XCTAssertEqual(snapshot.lockedBootBlockedQueryCount, 2)
        XCTAssertEqual(snapshot.lockedBootAllowedQueryCount, 2)
        XCTAssertEqual(snapshot.lockedBootFailClosedQueryCount, 1)
        XCTAssertNil(snapshot.lockedBootWindowEndedAt,
                     "Bucketing serves must not stamp the window end — only the readable reload does.")
    }

    func testLockedBootWindowCoversComparesAgainstTheObservedLockedBoundaryOnly() {
        var snapshot = TunnelHealthSnapshot()
        let decisionTime = Date(timeIntervalSince1970: 1_700_000_000)

        // A never-locked boot (no stamp, no observation) admits nothing — ever.
        XCTAssertFalse(snapshot.lockedBootWindowCovers(decisionAt: decisionTime, lastObservedLockedAt: nil))

        // Window still OPEN (no end stamp): the caller's live locked observation bounds
        // membership. There is deliberately NO flag fast path — the locked-boot store
        // flag clears only at the throttled readable reload, so it stays set for up to
        // one refresh interval of post-unlock traffic (Codex review, #381).
        XCTAssertTrue(snapshot.lockedBootWindowCovers(decisionAt: decisionTime,
                                                      lastObservedLockedAt: decisionTime.addingTimeInterval(1)))
        XCTAssertFalse(snapshot.lockedBootWindowCovers(decisionAt: decisionTime,
                                                       lastObservedLockedAt: decisionTime.addingTimeInterval(-1)),
                       "A decision after the last locked observation is ambiguous — dropped, never admitted.")

        // Window ENDED: the frozen stamp is the boundary and takes precedence over any
        // (stale) live observation the caller still holds.
        snapshot.markLockedBootWindowEnded(at: decisionTime.addingTimeInterval(1))
        XCTAssertTrue(snapshot.lockedBootWindowCovers(decisionAt: decisionTime, lastObservedLockedAt: nil),
                      "A pre-unlock straggler bucketed after the window stamp must be admitted by the boundary comparison.")
        XCTAssertFalse(snapshot.lockedBootWindowCovers(decisionAt: decisionTime.addingTimeInterval(2),
                                                       lastObservedLockedAt: decisionTime.addingTimeInterval(10)),
                       "Post-window traffic is never evidence, whatever the caller passes.")
    }

    func testLockedBootWindowEndStampIsFirstTransitionWins() {
        var snapshot = TunnelHealthSnapshot()
        let unlock = Date(timeIntervalSince1970: 1_700_000_000)
        snapshot.markLockedBootWindowEnded(at: unlock)
        // A later readable reload must not move the stamp off the actual unlock boundary.
        snapshot.markLockedBootWindowEnded(at: unlock.addingTimeInterval(600))
        XCTAssertEqual(snapshot.lockedBootWindowEndedAt, unlock)
    }

    func testDecodingOldHealthDefaultsLockedBootEvidenceToEmpty() throws {
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

        XCTAssertEqual(snapshot.lockedBootBlockedQueryCount, 0)
        XCTAssertEqual(snapshot.lockedBootAllowedQueryCount, 0)
        XCTAssertEqual(snapshot.lockedBootFailClosedQueryCount, 0)
        XCTAssertNil(snapshot.lockedBootWindowEndedAt)
    }

    func testLockedBootEvidenceSurvivesAnEncodeDecodeRoundtrip() throws {
        var snapshot = TunnelHealthSnapshot()
        snapshot.recordLockedBootServe(action: .block, reason: .blocklist)
        snapshot.recordLockedBootServe(action: .allow, reason: .defaultAllow)
        snapshot.markLockedBootWindowEnded(at: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.lockedBootBlockedQueryCount, 1)
        XCTAssertEqual(decoded.lockedBootAllowedQueryCount, 1)
        XCTAssertEqual(decoded.lockedBootFailClosedQueryCount, 0)
        XCTAssertEqual(decoded.lockedBootWindowEndedAt, snapshot.lockedBootWindowEndedAt,
                       "The window-end stamp is the evidence's timestamp anchor — it must persist exactly.")
    }

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

    func testHealthRoundTripPreservesLatencyHistogramAndSuccessDuration() throws {
        var histogram = DNSLatencyHistogram()
        histogram.record(durationMilliseconds: 30)
        histogram.record(durationMilliseconds: 5_000)
        let snapshot = TunnelHealthSnapshot(
            lastUpstreamSuccessDurationMilliseconds: 42,
            upstreamLatencyHistogram: histogram
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.upstreamLatencyHistogram, histogram)
        XCTAssertEqual(decoded.upstreamLatencyHistogram.sampleCount, 2)
        XCTAssertEqual(decoded.lastUpstreamSuccessDurationMilliseconds, 42)
    }

    func testDecodingOldHealthDefaultsLatencyHistogramToEmpty() throws {
        // A payload predating the histogram field decodes to an empty histogram.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(TunnelHealthSnapshot())) as? [String: Any]
        )
        object.removeValue(forKey: "upstreamLatencyHistogram")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.upstreamLatencyHistogram, DNSLatencyHistogram())
        XCTAssertEqual(decoded.upstreamLatencyHistogram.sampleCount, 0)
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
