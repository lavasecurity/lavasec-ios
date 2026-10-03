import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// Slice A of the connectivity-health module scaffold: the `HealthVerdict` value type, the
/// `ConnectivityHealthSignal` seam, and the first module `DNSResolutionHealth`. These are pure
/// value types, so they get real behavioral tests (never source pins), per the codebase's
/// policy-type convention.
final class HealthVerdictTests: XCTestCase {
    func testHealthyCarriesNoReason() {
        XCTAssertEqual(HealthVerdict.healthy.level, .healthy)
        XCTAssertNil(HealthVerdict.healthy.reason)
    }

    func testDegradedAndDownCarryTheirReason() {
        XCTAssertEqual(HealthVerdict.degraded("dns-slow").level, .degraded)
        XCTAssertEqual(HealthVerdict.degraded("dns-slow").reason, "dns-slow")
        XCTAssertEqual(HealthVerdict.down("needs-reconnect").level, .down)
        XCTAssertEqual(HealthVerdict.down("needs-reconnect").reason, "needs-reconnect")
    }

    func testLevelCasesAreHealthyDegradedDown() {
        XCTAssertEqual(HealthVerdict.Level.allCases, [.healthy, .degraded, .down])
    }

    func testEqualityDiscriminatesLevelAndReason() {
        XCTAssertEqual(HealthVerdict.degraded("a"), .degraded("a"))
        // Same reason, different level.
        XCTAssertNotEqual(HealthVerdict.degraded("a"), .down("a"))
        // Same level, different reason.
        XCTAssertNotEqual(HealthVerdict.degraded("a"), .degraded("b"))
        // Healthy (nil reason) is distinct from a degraded/down that happens to share nothing.
        XCTAssertNotEqual(HealthVerdict.healthy, .degraded("a"))
    }
}

final class DNSResolutionHealthTests: XCTestCase {
    private static let refDate = Date(timeIntervalSinceReferenceDate: 800_720_000)

    /// One input per policy severity, each paired with the LITERAL verdict the module must produce.
    ///
    /// The expected verdict is written out per case — NOT computed by a helper that mirrors the
    /// module's own `switch` — so a change to the module's mapping cannot be masked by an identical
    /// change to a shared expectation (PR #552). `expectedSeverity` is asserted against the
    /// live policy in the parity test, so the (severity, verdict) pairing here is the recast's whole
    /// specification stated as data. The field combinations are the ones
    /// `ProtectionConnectivityPolicyTests` uses to pin each severity.
    private struct Case {
        let name: String
        let health: TunnelHealthSnapshot
        let now: Date
        let expectedSeverity: ProtectionConnectivitySeverity
        let expectedVerdict: HealthVerdict
    }

    private static func cases() -> [Case] {
        let t = refDate
        let s = refDate
        return [
            Case(
                name: "needs-reconnect (post-network-change timeout streak)",
                health: TunnelHealthSnapshot(
                    lastFailureReason: "timeout",
                    upstreamSuccessCount: 20,
                    upstreamFailureCount: 3,
                    consecutiveUpstreamFailureCount: 3,
                    lastNetworkChangeAt: t,
                    lastResolverRuntimeResetAt: t.addingTimeInterval(1),
                    lastResolverRuntimeResetReason: "network-path-changed",
                    resolverRuntimeResetCount: 1,
                    lastUpstreamSuccessAt: t.addingTimeInterval(-30),
                    lastUpstreamFailureAt: t.addingTimeInterval(8)),
                now: t.addingTimeInterval(12),
                expectedSeverity: .needsReconnect,
                expectedVerdict: .down("needs-reconnect")),
            Case(
                name: "healthy (single timeout after long uptime)",
                health: TunnelHealthSnapshot(
                    startedAt: s,
                    lastFailureReason: "timeout",
                    upstreamSuccessCount: 120,
                    upstreamFailureCount: 1,
                    consecutiveUpstreamFailureCount: 1,
                    lastUpstreamSuccessAt: s.addingTimeInterval(3_570),
                    lastUpstreamFailureAt: s.addingTimeInterval(3_600)),
                now: s.addingTimeInterval(3_601),
                expectedSeverity: .healthy,
                expectedVerdict: .healthy),
            Case(
                name: "network-unavailable (path not satisfied)",
                health: TunnelHealthSnapshot(
                    networkPathIsSatisfied: false,
                    lastNetworkChangeAt: t),
                now: t.addingTimeInterval(12),
                expectedSeverity: .networkUnavailable,
                expectedVerdict: .down("network-unavailable")),
            Case(
                name: "device-dns-fallback (active mode after network change)",
                health: TunnelHealthSnapshot(
                    lastResolverTransport: .deviceDNS,
                    deviceDNSFallbackModeActive: true,
                    lastDeviceDNSFallbackActivatedAt: t.addingTimeInterval(2),
                    deviceDNSFallbackActivationCount: 1,
                    lastNetworkChangeAt: t,
                    lastUpstreamSuccessAt: t.addingTimeInterval(4)),
                now: t.addingTimeInterval(30),
                expectedSeverity: .usingDeviceDNSFallback,
                expectedVerdict: .degraded("device-dns-fallback")),
            Case(
                name: "encrypted-fallback (serving DoH covers a failing primary probe)",
                health: TunnelHealthSnapshot(
                    lastFailureReason: "receive-failed",
                    consecutiveUpstreamFailureCount: 1,
                    lastDNSSmokeProbeAt: t.addingTimeInterval(3),
                    lastDNSSmokeProbeSucceeded: false,
                    consecutiveDNSSmokeProbeFailureCount: 3,
                    consecutiveRejectedSmokeResponseCount: 0,
                    lastNetworkChangeAt: t,
                    lastEncryptedFallbackSuccessAt: t.addingTimeInterval(12)),
                now: t.addingTimeInterval(17),
                expectedSeverity: .usingEncryptedFallback,
                expectedVerdict: .degraded("encrypted-fallback")),
            Case(
                name: "dns-slow (repeated slow successful answers)",
                health: TunnelHealthSnapshot(
                    startedAt: s,
                    upstreamSuccessCount: 12,
                    lastUpstreamSuccessAt: s.addingTimeInterval(60),
                    lastUpstreamDurationMilliseconds: 3_200,
                    slowUpstreamResponseCount: 4,
                    consecutiveSlowUpstreamResponseCount: 3,
                    lastSlowUpstreamResponseAt: s.addingTimeInterval(60)),
                now: s.addingTimeInterval(61),
                expectedSeverity: .dnsSlow,
                expectedVerdict: .degraded("dns-slow")),
            Case(
                name: "recovering (rejected response below the reconnect threshold)",
                health: TunnelHealthSnapshot(
                    startedAt: s,
                    lastFailureReason: "rejected-response",
                    consecutiveUpstreamFailureCount: 1,
                    lastDNSSmokeProbeAt: s.addingTimeInterval(300),
                    lastDNSSmokeProbeSucceeded: false,
                    consecutiveDNSSmokeProbeFailureCount: 1,
                    consecutiveRejectedSmokeResponseCount: 2,
                    rejectedSmokeResponseResolverIdentity: "device:220.159.212.200,220.159.212.201",
                    lastResolverRuntimeResetAt: s),
                now: s.addingTimeInterval(301),
                expectedSeverity: .recovering,
                expectedVerdict: .degraded("recovering")),
        ]
    }

    func testTheSignalIdentifiesAsDNSResolution() {
        XCTAssertEqual(DNSResolutionHealth().id, .dnsResolution)
        // The id space is fixed from the start so B/C are adds, not renumbers.
        XCTAssertEqual(ConnectivityHealthSignalID.allCases, [.dnsResolution, .linkPath, .dataPath])
    }

    func testEachSeverityMapsToTheExpectedLevelAndReason() {
        let signal = DNSResolutionHealth()
        for c in Self.cases() {
            let verdict = signal.verdict(
                for: ConnectivityHealthInputs(isConnected: true, health: c.health),
                now: c.now)
            XCTAssertEqual(verdict, c.expectedVerdict, c.name)
            // A non-healthy reason is exactly the severity's own diagnostic label — no parallel
            // vocabulary that could drift from the labels the notification/UI layers key on. Tying
            // it to `diagnosticLabel` here (not just the literal) also catches a typo in the literal.
            if c.expectedSeverity == .healthy {
                XCTAssertNil(verdict.reason, c.name)
            } else {
                XCTAssertEqual(verdict.reason, c.expectedSeverity.diagnosticLabel, c.name)
            }
        }
    }

    /// THE no-op guard. Each fixture's severity is asserted against the UNMODIFIED
    /// `ProtectionConnectivityPolicy.assessment(...).severity`, and the module's verdict against the
    /// per-case literal — so a divergence in EITHER the policy's classification or the module's
    /// mapping turns it RED, and neither can hide behind a helper that mirrors the other. The
    /// coverage assertion proves the battery actually exercises all seven severities, so a future
    /// edit that broke one branch could not hide behind a battery that no longer reaches it.
    func testVerdictNeverDivergesFromTheDelegatedPolicy() {
        let signal = DNSResolutionHealth()
        var severitiesSeen: Set<ProtectionConnectivitySeverity> = []
        for c in Self.cases() {
            let inputs = ConnectivityHealthInputs(isConnected: true, health: c.health)
            let severity = ProtectionConnectivityPolicy
                .assessment(isConnected: true, health: c.health, now: c.now).severity
            severitiesSeen.insert(severity)
            XCTAssertEqual(severity, c.expectedSeverity, "\(c.name): fixture no longer triggers its severity")
            XCTAssertEqual(signal.verdict(for: inputs, now: c.now), c.expectedVerdict, c.name)
        }
        XCTAssertEqual(
            severitiesSeen,
            [.healthy, .recovering, .usingDeviceDNSFallback, .usingEncryptedFallback,
             .dnsSlow, .networkUnavailable, .needsReconnect],
            "the parity battery must exercise every severity or it can pass vacuously")
    }

    /// The disconnected shortcut: `assessment` returns healthy when not connected, so the module
    /// mirrors it (Slice A is a no-op recast). A disconnected tunnel is not "carrying traffic", but
    /// this healthy verdict is a don't-care: the supervisor (Slice D) evaluates connectivity health
    /// only while connected, so it never surfaces this value. Pinned so the mirror stays faithful.
    func testDisconnectedReadsHealthyRegardlessOfEvidence() {
        let downWhileConnected = Self.cases().first { $0.expectedSeverity == .needsReconnect }!
        let verdict = DNSResolutionHealth().verdict(
            for: ConnectivityHealthInputs(isConnected: false, health: downWhileConnected.health),
            now: downWhileConnected.now)
        XCTAssertEqual(verdict, .healthy)
    }

    func testVerdictIsPureAndDeterministic() {
        let signal = DNSResolutionHealth()
        for c in Self.cases() {
            let inputs = ConnectivityHealthInputs(isConnected: true, health: c.health)
            let first = signal.verdict(for: inputs, now: c.now)
            let second = signal.verdict(for: inputs, now: c.now)
            XCTAssertEqual(first, second, "\(c.name): identical inputs must yield identical verdicts")
        }
    }

    func testUsableThroughTheExistentialProtocol() {
        let signal: any ConnectivityHealthSignal = DNSResolutionHealth()
        XCTAssertEqual(signal.id, .dnsResolution)
        let healthy = Self.cases().first { $0.expectedSeverity == .healthy }!
        let verdict = signal.verdict(
            for: ConnectivityHealthInputs(isConnected: true, health: healthy.health),
            now: healthy.now)
        XCTAssertEqual(verdict, .healthy)
    }
}
