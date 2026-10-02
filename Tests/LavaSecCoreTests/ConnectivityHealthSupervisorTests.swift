import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// Slice D: `ConnectivityHealthSupervisor` composes the three connectivity-health signals into one
/// `ConnectivityHealthAssessment`, gated by `DNSHealthAuthority`. Pure value type → behavioral tests.
///
/// The load-bearing property is the founder-agreed action gate: the data-path `upstream-quiet`
/// verdict must NEVER produce a `.reconnect`, and a chained (tunnel-owned) reconnect is clamped to
/// `.turnOff`. Those are pinned both directly and as an orthogonality sweep over the whole input
/// space, so the guarantee cannot pass vacuously.
final class ConnectivityHealthSupervisorTests: XCTestCase {
    private static let t = Date(timeIntervalSinceReferenceDate: 800_720_000)

    // MARK: Policy-verified DNS/link fixtures
    //
    // Each fixture's `(severity, action)` is asserted against the LIVE `ProtectionConnectivityPolicy`
    // in `testFixturesStillTriggerTheirPolicyClassification`, so if a fixture stops triggering its
    // severity the supervisor tests can't pass on a stale premise. Field combinations are the ones
    // `ProtectionConnectivityPolicyTests` / `DNSResolutionHealthTests` use to pin each severity.
    private struct Fixture {
        let name: String
        let health: TunnelHealthSnapshot
        let now: Date
        let policySeverity: ProtectionConnectivitySeverity
        let policyAction: ProtectionConnectivityAction
        /// The overall level while the data-path signal is healthy/absent (DNS+link alone).
        let baseOverallLevel: HealthVerdict.Level
    }

    private static func fixtures() -> [Fixture] {
        let t = Self.t
        return [
            Fixture(
                name: "healthy",
                health: TunnelHealthSnapshot(),
                now: t,
                policySeverity: .healthy,
                policyAction: .turnOff,
                baseOverallLevel: .healthy),
            Fixture(
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
                policySeverity: .needsReconnect,
                policyAction: .reconnect,
                baseOverallLevel: .down),
            Fixture(
                name: "network-unavailable (path not satisfied)",
                health: TunnelHealthSnapshot(networkPathIsSatisfied: false, lastNetworkChangeAt: t),
                now: t.addingTimeInterval(12),
                policySeverity: .networkUnavailable,
                policyAction: .turnOff,
                baseOverallLevel: .down),
            Fixture(
                name: "dns-slow (repeated slow successful answers)",
                health: TunnelHealthSnapshot(
                    startedAt: t,
                    upstreamSuccessCount: 12,
                    lastUpstreamSuccessAt: t.addingTimeInterval(60),
                    lastUpstreamDurationMilliseconds: 3_200,
                    slowUpstreamResponseCount: 4,
                    consecutiveSlowUpstreamResponseCount: 3,
                    lastSlowUpstreamResponseAt: t.addingTimeInterval(60)),
                now: t.addingTimeInterval(61),
                policySeverity: .dnsSlow,
                policyAction: .reconnect,
                baseOverallLevel: .degraded),
            Fixture(
                name: "device-dns-fallback (active mode after network change)",
                health: TunnelHealthSnapshot(
                    lastResolverTransport: .deviceDNS,
                    deviceDNSFallbackModeActive: true,
                    lastDeviceDNSFallbackActivatedAt: t.addingTimeInterval(2),
                    deviceDNSFallbackActivationCount: 1,
                    lastNetworkChangeAt: t,
                    lastUpstreamSuccessAt: t.addingTimeInterval(4)),
                now: t.addingTimeInterval(30),
                policySeverity: .usingDeviceDNSFallback,
                policyAction: .turnOff,
                baseOverallLevel: .degraded),
        ]
    }

    private static let physicalAuthority = DNSHealthAuthority(chainedIsLatched: false)
    private static let chainedAuthority = DNSHealthAuthority(chainedIsLatched: true)

    /// rx dominates tx — the normal browsing shape; data-path reads healthy.
    private static let dataPathHealthy = DataPathObservation(
        transmittedByteDelta: 20_000, receivedByteDelta: 400_000, hasHandshake: true)
    /// tx dominates flat rx over real volume — `DataPathHealth` reads `.down("upstream-quiet")`.
    private static let dataPathDown = DataPathObservation(
        transmittedByteDelta: 65_536, receivedByteDelta: 0, hasHandshake: true)

    private func inputs(
        _ fixture: Fixture, dataPath: DataPathObservation?
    ) -> ConnectivityHealthInputs {
        ConnectivityHealthInputs(isConnected: true, health: fixture.health, dataPath: dataPath)
    }

    // MARK: Fixture premise

    func testFixturesStillTriggerTheirPolicyClassification() {
        for f in Self.fixtures() {
            let assessment = ProtectionConnectivityPolicy.assessment(
                isConnected: true, health: f.health, now: f.now)
            XCTAssertEqual(assessment.severity, f.policySeverity, "\(f.name): severity drifted")
            XCTAssertEqual(assessment.primaryAction, f.policyAction, "\(f.name): action drifted")
        }
    }

    // MARK: Authority sanity

    func testAuthorityPermitsPhysicalReconnectOnlyWhenNotChained() {
        XCTAssertTrue(Self.physicalAuthority.physicalReconnectMayAct)
        XCTAssertFalse(Self.chainedAuthority.physicalReconnectMayAct)
    }

    // MARK: Composition — overall level

    func testAllHealthyReadsHealthyAndTurnOff() {
        let healthy = Self.fixtures().first { $0.name == "healthy" }!
        let assessment = ConnectivityHealthSupervisor().assess(
            for: inputs(healthy, dataPath: Self.dataPathHealthy),
            authority: Self.chainedAuthority,
            now: healthy.now)
        XCTAssertEqual(assessment.overallLevel, .healthy)
        XCTAssertEqual(assessment.recommendedAction, .turnOff)
        XCTAssertTrue(assessment.unhealthySignals.isEmpty)
    }

    func testOverallLevelIsWorstOfTheSignals() {
        // A DEGRADED DNS dimension + a DOWN data-path → overall down (down beats degraded). Physical
        // owner so the DNS signal is live (it is short-circuited to healthy under the tunnel owner).
        let slow = Self.fixtures().first { $0.name.hasPrefix("dns-slow") }!
        let assessment = ConnectivityHealthSupervisor().assess(
            for: inputs(slow, dataPath: Self.dataPathDown),
            authority: Self.physicalAuthority,
            now: slow.now)
        XCTAssertEqual(assessment.verdicts[.dnsResolution]?.level, .degraded)
        XCTAssertEqual(assessment.verdicts[.dataPath], .down("upstream-quiet"))
        XCTAssertEqual(assessment.overallLevel, .down)
    }

    func testDataPathDownAloneSurfacesDownWithTheUpstreamQuietReason() {
        let healthy = Self.fixtures().first { $0.name == "healthy" }!
        let assessment = ConnectivityHealthSupervisor().assess(
            for: inputs(healthy, dataPath: Self.dataPathDown),
            authority: Self.chainedAuthority,
            now: healthy.now)
        XCTAssertEqual(assessment.overallLevel, .down)
        // The DNS + link dimensions are healthy; only the data path is down.
        XCTAssertEqual(assessment.verdicts[.dnsResolution], .healthy)
        XCTAssertEqual(assessment.verdicts[.linkPath], .healthy)
        XCTAssertEqual(
            assessment.unhealthySignals.map(\.id), [.dataPath],
            "only the data-path dimension is unhealthy")
        XCTAssertEqual(assessment.unhealthySignals.first?.verdict.reason, "upstream-quiet")
    }

    // MARK: The action gate — the founder-agreed guarantee

    /// upstream-quiet is unfixable by a restart (#548); the supervisor must never turn it into a
    /// reconnect, under EITHER owner. This is the headline guarantee.
    func testDataPathDownNeverRecommendsReconnect() {
        let healthy = Self.fixtures().first { $0.name == "healthy" }!
        for authority in [Self.physicalAuthority, Self.chainedAuthority] {
            let assessment = ConnectivityHealthSupervisor().assess(
                for: inputs(healthy, dataPath: Self.dataPathDown),
                authority: authority,
                now: healthy.now)
            XCTAssertEqual(
                assessment.recommendedAction, .turnOff,
                "an upstream-quiet data path must never surface a reconnect")
        }
    }

    /// Chained + connected but no handshake yet → the data path reports establishing. It surfaces as
    /// down (not the old false "Healthy") and, like every data-path verdict, never drives a reconnect.
    func testDataPathEstablishingSurfacesAsDownAndNeverRecommendsReconnect() {
        let healthy = Self.fixtures().first { $0.name == "healthy" }!
        let connecting = DataPathObservation(
            transmittedByteDelta: 0, receivedByteDelta: 0, hasHandshake: false)
        for authority in [Self.physicalAuthority, Self.chainedAuthority] {
            let assessment = ConnectivityHealthSupervisor().assess(
                for: ConnectivityHealthInputs(
                    isConnected: true, health: healthy.health, dataPath: connecting),
                authority: authority,
                now: healthy.now)
            XCTAssertEqual(assessment.verdict(for: .dataPath), .down("tunnel-connecting"))
            XCTAssertEqual(assessment.overallLevel, .down)
            XCTAssertEqual(
                assessment.recommendedAction, .turnOff,
                "an establishing chained tunnel must never surface a reconnect")
        }
    }

    /// A genuine DNS `.needsReconnect` surfaces a reconnect ONLY under physical-path ownership; while
    /// the tunnel supervisor owns health it is clamped to `.turnOff` (a physical restart is the
    /// INV-CHAIN-1 leak / #548 loop).
    func testDNSReconnectIsGatedByOwnership() {
        for f in Self.fixtures() where f.policyAction == .reconnect {
            let physical = ConnectivityHealthSupervisor().assess(
                for: inputs(f, dataPath: nil), authority: Self.physicalAuthority, now: f.now)
            XCTAssertEqual(physical.recommendedAction, .reconnect, "\(f.name): physical owner may reconnect")

            let chained = ConnectivityHealthSupervisor().assess(
                for: inputs(f, dataPath: nil), authority: Self.chainedAuthority, now: f.now)
            XCTAssertEqual(chained.recommendedAction, .turnOff, "\(f.name): chained owner clamps reconnect")
        }
    }

    /// The data path does not SUPPRESS a legitimate reconnect either: a `.needsReconnect` DNS state
    /// under physical ownership still recommends reconnect even when the data path is simultaneously
    /// down. Together with the test above this proves the data path is orthogonal to the action.
    func testDataPathDownDoesNotSuppressALegitimateReconnect() {
        let reconnecting = Self.fixtures().first { $0.name.hasPrefix("needs-reconnect") }!
        let assessment = ConnectivityHealthSupervisor().assess(
            for: inputs(reconnecting, dataPath: Self.dataPathDown),
            authority: Self.physicalAuthority,
            now: reconnecting.now)
        XCTAssertEqual(assessment.recommendedAction, .reconnect)
        XCTAssertEqual(assessment.overallLevel, .down)
    }

    /// The non-vacuous enforcement: across EVERY DNS/link fixture × BOTH owners, toggling the data
    /// path healthy → down → absent must leave `recommendedAction` identical. The data-path signal
    /// can neither add nor remove a reconnect — it is structurally excluded from the action.
    func testDataPathStateNeverChangesTheRecommendedAction() {
        let supervisor = ConnectivityHealthSupervisor()
        for f in Self.fixtures() {
            for authority in [Self.physicalAuthority, Self.chainedAuthority] {
                let actions = [Self.dataPathHealthy, Self.dataPathDown, nil].map { dp in
                    supervisor.assess(
                        for: inputs(f, dataPath: dp), authority: authority, now: f.now
                    ).recommendedAction
                }
                XCTAssertEqual(
                    Set(actions), [actions[0]],
                    "\(f.name): data-path state changed the action — it must be action-orthogonal")
            }
        }
    }

    // MARK: DNS quiescence while the tunnel supervisor owns health (Kilo #555)

    /// The provider freezes the physical failure fields while chained, so `DNSResolutionHealth` (which
    /// reads them) would otherwise report a permanent stale `.down`. Under the tunnel owner the
    /// supervisor short-circuits the DNS signal to healthy, so the row reflects link + data path — not
    /// stale physical DNS — while under the physical owner the DNS signal stays live.
    func testDNSResolutionSignalIsQuiescentWhileTunnelSupervisorOwnsHealth() {
        let reconnecting = Self.fixtures().first { $0.name.hasPrefix("needs-reconnect") }!
        let supervisor = ConnectivityHealthSupervisor()

        // Physical owner: the DNS signal is live — it reports the (stale-or-not) physical verdict.
        let physical = supervisor.assess(
            for: inputs(reconnecting, dataPath: nil),
            authority: Self.physicalAuthority,
            now: reconnecting.now)
        XCTAssertEqual(physical.verdict(for: .dnsResolution), .down("needs-reconnect"))
        XCTAssertEqual(physical.overallLevel, .down)

        // Tunnel-supervisor owner: DNS is quiescent; with a healthy link and no data-path sample the
        // whole row is healthy despite the frozen physical failure evidence.
        let chained = supervisor.assess(
            for: inputs(reconnecting, dataPath: nil),
            authority: Self.chainedAuthority,
            now: reconnecting.now)
        XCTAssertEqual(chained.verdict(for: .dnsResolution), .healthy)
        XCTAssertEqual(chained.overallLevel, .healthy)

        // The data path still speaks while chained: a quiet upstream surfaces even though DNS is silenced.
        let chainedQuiet = supervisor.assess(
            for: inputs(reconnecting, dataPath: Self.dataPathDown),
            authority: Self.chainedAuthority,
            now: reconnecting.now)
        XCTAssertEqual(chainedQuiet.verdict(for: .dataPath), .down("upstream-quiet"))
        XCTAssertEqual(chainedQuiet.verdict(for: .dnsResolution), .healthy)
        XCTAssertEqual(chainedQuiet.overallLevel, .down)
    }

    // MARK: Disconnected

    func testDisconnectedReadsHealthyAndTurnOffUnderBothOwners() {
        let reconnecting = Self.fixtures().first { $0.name.hasPrefix("needs-reconnect") }!
        for authority in [Self.physicalAuthority, Self.chainedAuthority] {
            let assessment = ConnectivityHealthSupervisor().assess(
                for: ConnectivityHealthInputs(
                    isConnected: false, health: reconnecting.health, dataPath: Self.dataPathDown),
                authority: authority,
                now: reconnecting.now)
            XCTAssertEqual(assessment.overallLevel, .healthy)
            XCTAssertEqual(assessment.recommendedAction, .turnOff)
        }
    }

    // MARK: Assessment conveniences

    func testVerdictForUnevaluatedSignalReadsHealthy() {
        // A supervisor built with only the DNS signal leaves link/data-path unevaluated → healthy.
        let dnsOnly = ConnectivityHealthSupervisor(signals: [DNSResolutionHealth()])
        let healthy = Self.fixtures().first { $0.name == "healthy" }!
        let assessment = dnsOnly.assess(
            for: inputs(healthy, dataPath: Self.dataPathDown),
            authority: Self.chainedAuthority,
            now: healthy.now)
        XCTAssertEqual(assessment.verdict(for: .dataPath), .healthy)
        XCTAssertNil(assessment.verdicts[.dataPath])
        // With the data-path signal absent, its down observation cannot move the overall level.
        XCTAssertEqual(assessment.overallLevel, .healthy)
    }

    func testUnhealthySignalsAreInStableAllCasesOrder() {
        // network-unavailable makes BOTH the DNS and link dimensions down; the data path is down too.
        // Physical owner so the DNS dimension is live (quiescent under the tunnel owner).
        let linkDown = Self.fixtures().first { $0.name.hasPrefix("network-unavailable") }!
        let assessment = ConnectivityHealthSupervisor().assess(
            for: inputs(linkDown, dataPath: Self.dataPathDown),
            authority: Self.physicalAuthority,
            now: linkDown.now)
        XCTAssertEqual(
            assessment.unhealthySignals.map(\.id), [.dnsResolution, .linkPath, .dataPath],
            "unhealthy signals surface in allCases order, not dictionary order")
    }

    func testPureAndDeterministic() {
        let supervisor = ConnectivityHealthSupervisor()
        let reconnecting = Self.fixtures().first { $0.name.hasPrefix("needs-reconnect") }!
        let i = inputs(reconnecting, dataPath: Self.dataPathDown)
        XCTAssertEqual(
            supervisor.assess(for: i, authority: Self.physicalAuthority, now: reconnecting.now),
            supervisor.assess(for: i, authority: Self.physicalAuthority, now: reconnecting.now))
    }
}
