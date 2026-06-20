import XCTest
@testable import LavaSecCore

final class ProtectionConnectivityNotificationPolicyTests: XCTestCase {
    func testDeviceDNSFallbackCreatesBriefNotificationForFreshUnsentEvent() {
        let now = Date(timeIntervalSince1970: 100)
        let eventAt = now.addingTimeInterval(-2)
        let health = TunnelHealthSnapshot(
            lastDeviceDNSFallbackActivatedAt: eventAt,
            lastNetworkChangeAt: now.addingTimeInterval(-4)
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .usingDeviceDNSFallback,
                primaryAction: .turnOff
            ),
            health: health,
            history: .empty,
            now: now
        )

        XCTAssertEqual(notification?.kind, .deviceDNSFallback)
        XCTAssertEqual(notification?.identifier, "device-dns-fallback:98")
        XCTAssertEqual(notification?.title, "Lava switched to Device DNS")
        XCTAssertEqual(notification?.body, "Network DNS rules changed. Filtering is still on.")
        XCTAssertEqual(notification?.supersededNotificationIdentifiers, [])
    }

    func testNetworkUnavailableCreatesBriefNotificationForFreshUnsentEvent() {
        let now = Date(timeIntervalSince1970: 200)
        let eventAt = now.addingTimeInterval(-5)
        let health = TunnelHealthSnapshot(
            networkPathIsSatisfied: false,
            lastNetworkChangeAt: eventAt
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .networkUnavailable,
                primaryAction: .turnOff
            ),
            health: health,
            history: .empty,
            now: now
        )

        XCTAssertEqual(notification?.kind, .networkUnavailable)
        XCTAssertEqual(notification?.identifier, "network-unavailable:195")
        XCTAssertEqual(notification?.title, "Lava needs a network")
        XCTAssertEqual(notification?.body, "No internet path is available. Lava will resume when the network returns.")
    }

    func testReconnectNeededCreatesBriefNotificationForFreshUnsentSmokeProbeFailure() {
        let now = Date(timeIntervalSince1970: 300)
        let eventAt = now.addingTimeInterval(-3)
        let health = TunnelHealthSnapshot(
            lastDNSSmokeProbeAt: eventAt,
            lastDNSSmokeProbeSucceeded: false,
            lastNetworkChangeAt: now.addingTimeInterval(-8)
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .needsReconnect,
                primaryAction: .reconnect
            ),
            health: health,
            history: .empty,
            now: now
        )

        XCTAssertEqual(notification?.kind, .reconnectNeeded)
        XCTAssertEqual(notification?.identifier, "reconnect-needed:297")
        XCTAssertEqual(notification?.title, "Reconnect Lava")
        XCTAssertEqual(notification?.body, "DNS is not resolving on this network. Tap to reconnect protection.")
    }

    func testNotificationPolicySkipsHealthyDuplicateAndStaleEvents() {
        let now = Date(timeIntervalSince1970: 400)
        let recentEventAt = now.addingTimeInterval(-10)
        let staleEventAt = now.addingTimeInterval(-180)
        let recentHealth = TunnelHealthSnapshot(
            lastDeviceDNSFallbackActivatedAt: recentEventAt,
            lastNetworkChangeAt: now.addingTimeInterval(-20)
        )
        let recentAssessment = ProtectionConnectivityAssessment(
            severity: .usingDeviceDNSFallback,
            primaryAction: .turnOff
        )

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: recentAssessment,
            health: recentHealth,
            history: ProtectionConnectivityNotificationHistory(
                lastDeliveredNotificationID: "device-dns-fallback:390"
            ),
            now: now
        ))

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: TunnelHealthSnapshot(
                lastDNSSmokeProbeAt: recentEventAt,
                lastDNSSmokeProbeSucceeded: true,
                lastNetworkChangeAt: now.addingTimeInterval(-20)
            ),
            history: .empty,
            now: now
        ))

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .networkUnavailable,
                primaryAction: .turnOff
            ),
            health: TunnelHealthSnapshot(
                networkPathIsSatisfied: false,
                lastNetworkChangeAt: staleEventAt
            ),
            history: .empty,
            now: now
        ))
    }

    func testUnresolvedProblemSuppressesQuickRepeatProblemNotifications() {
        let now = Date(timeIntervalSince1970: 500)
        let eventAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "device-dns-fallback:480",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "device-dns-fallback:480",
            unresolvedProblemKind: .deviceDNSFallback
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .networkUnavailable,
                primaryAction: .turnOff
            ),
            health: TunnelHealthSnapshot(
                networkPathIsSatisfied: false,
                lastNetworkChangeAt: eventAt
            ),
            history: history,
            now: now
        )

        XCTAssertNil(notification)
    }

    func testReconnectNeededEscalatesOverOutstandingDeviceDNSFallbackBanner() {
        // The headline escalation: a wedge after a Device-DNS fallback must surface the
        // actionable "Reconnect" prompt immediately — superseding the stale "switched to
        // Device DNS" banner — instead of waiting out the 600s problem cooldown.
        let now = Date(timeIntervalSince1970: 1000)
        let eventAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "device-dns-fallback:900",
            lastDeliveredAt: now.addingTimeInterval(-20), // well within the 600s cooldown
            unresolvedProblemNotificationID: "device-dns-fallback:900",
            unresolvedProblemKind: .deviceDNSFallback
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .needsReconnect,
                primaryAction: .reconnect
            ),
            health: TunnelHealthSnapshot(
                lastDNSSmokeProbeAt: eventAt,
                lastDNSSmokeProbeSucceeded: false,
                lastNetworkChangeAt: now.addingTimeInterval(-30)
            ),
            history: history,
            now: now
        )

        XCTAssertEqual(notification?.kind, .reconnectNeeded)
        XCTAssertEqual(notification?.identifier, "reconnect-needed:997")
        XCTAssertEqual(notification?.supersededNotificationIdentifiers, ["device-dns-fallback:900"])
    }

    func testReconnectNeededEscalatesOverOutstandingNetworkUnavailableBanner() {
        // Network returned but DNS is wedged: the "needs a network" banner should be
        // superseded by the actionable "Reconnect" prompt, again bypassing the cooldown.
        let now = Date(timeIntervalSince1970: 1100)
        let eventAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "network-unavailable:1000",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "network-unavailable:1000",
            unresolvedProblemKind: .networkUnavailable
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .needsReconnect,
                primaryAction: .reconnect
            ),
            health: TunnelHealthSnapshot(
                lastDNSSmokeProbeAt: eventAt,
                lastDNSSmokeProbeSucceeded: false,
                lastNetworkChangeAt: now.addingTimeInterval(-30)
            ),
            history: history,
            now: now
        )

        XCTAssertEqual(notification?.kind, .reconnectNeeded)
        XCTAssertEqual(notification?.supersededNotificationIdentifiers, ["network-unavailable:1000"])
    }

    func testOutstandingReconnectBannerIsNotDowngradedByLesserProblem() {
        // Escalation is upward-only: once the actionable "Reconnect" banner is up, a
        // lower-ranked problem (a Device-DNS fallback here) must NOT replace it mid-cooldown.
        let now = Date(timeIntervalSince1970: 1200)
        let eventAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnect-needed:1100",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "reconnect-needed:1100",
            unresolvedProblemKind: .reconnectNeeded
        )

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .usingDeviceDNSFallback,
                primaryAction: .turnOff
            ),
            health: TunnelHealthSnapshot(
                lastDeviceDNSFallbackActivatedAt: eventAt,
                lastNetworkChangeAt: now.addingTimeInterval(-30)
            ),
            history: history,
            now: now
        ))
    }

    func testSlowDNSProducesItsOwnNotificationKind() {
        // Slow DNS no longer reuses the reconnect-needed kind — it has a distinct kind
        // (and identifier prefix) so history can tell a soft "slow" banner apart from a
        // hard outage.
        let now = Date(timeIntervalSince1970: 1500)
        let eventAt = now.addingTimeInterval(-3)

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(severity: .dnsSlow, primaryAction: .reconnect),
            health: TunnelHealthSnapshot(
                lastNetworkChangeAt: now.addingTimeInterval(-30),
                lastSlowUpstreamResponseAt: eventAt
            ),
            history: .empty,
            now: now
        )

        XCTAssertEqual(notification?.kind, .dnsSlow)
        XCTAssertEqual(notification?.identifier, "dns-slow:1497")
        XCTAssertEqual(notification?.title, "Lava DNS is slow")
    }

    func testSlowDNSDoesNotEscalateOverOutstandingDeviceDNSFallbackBanner() {
        // Slow DNS is a soft degradation, not a hard outage — it ranks with the
        // non-actionable banners and must not steal a standing one.
        let now = Date(timeIntervalSince1970: 1300)
        let eventAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "device-dns-fallback:1200",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "device-dns-fallback:1200",
            unresolvedProblemKind: .deviceDNSFallback
        )

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(severity: .dnsSlow, primaryAction: .reconnect),
            health: TunnelHealthSnapshot(
                lastNetworkChangeAt: now.addingTimeInterval(-30),
                lastSlowUpstreamResponseAt: eventAt
            ),
            history: history,
            now: now
        ))
    }

    func testReconnectNeededEscalatesOverOutstandingSlowDNSBanner() {
        // The regression Codex caught: once a "DNS is slow" banner is outstanding, DNS
        // worsening to a full outage must upgrade the user to the actionable "Reconnect"
        // copy. Because dnsSlow is now a distinct kind (rank 1) from reconnectNeeded
        // (rank 2), the hard-outage candidate outranks it and supersedes the stale banner
        // instead of being blocked by the unresolved-problem guard.
        let now = Date(timeIntervalSince1970: 1400)
        let eventAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "dns-slow:1300",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "dns-slow:1300",
            unresolvedProblemKind: .dnsSlow
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(severity: .needsReconnect, primaryAction: .reconnect),
            health: TunnelHealthSnapshot(
                lastDNSSmokeProbeAt: eventAt,
                lastDNSSmokeProbeSucceeded: false,
                lastNetworkChangeAt: now.addingTimeInterval(-30)
            ),
            history: history,
            now: now
        )

        XCTAssertEqual(notification?.kind, .reconnectNeeded)
        XCTAssertEqual(notification?.title, "Reconnect Lava")
        XCTAssertEqual(notification?.supersededNotificationIdentifiers, ["dns-slow:1300"])
    }

    func testProblemNotificationsRespectCooldownEvenAfterPreviousProblemResolved() {
        let now = Date(timeIntervalSince1970: 600)
        let eventAt = now.addingTimeInterval(-5)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnected:device-dns-fallback:500",
            lastDeliveredAt: now.addingTimeInterval(-120)
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(
                severity: .networkUnavailable,
                primaryAction: .turnOff
            ),
            health: TunnelHealthSnapshot(
                networkPathIsSatisfied: false,
                lastNetworkChangeAt: eventAt
            ),
            history: history,
            now: now
        )

        XCTAssertNil(notification)
    }

    func testResolvedProblemSurfacesReconnectedAcknowledgementAfterRealForwardingSuccess() {
        let now = Date(timeIntervalSince1970: 700)
        let successAt = now.addingTimeInterval(-4)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnect-needed:600",
            lastDeliveredAt: now.addingTimeInterval(-90),
            unresolvedProblemNotificationID: "reconnect-needed:600",
            unresolvedProblemKind: .reconnectNeeded
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: TunnelHealthSnapshot(
                lastNetworkChangeAt: now.addingTimeInterval(-20),
                lastPrimaryUpstreamSuccessAt: successAt
            ),
            history: history,
            now: now
        )

        // A "reconnect needed" the user was warned about gets a positive recovery
        // confirmation once a real client query resolves through the tunnel,
        // superseding the problem banner so the user knows it's actually back.
        XCTAssertEqual(notification?.kind, .reconnected)
        XCTAssertEqual(notification?.identifier, "reconnected:reconnect-needed:600")
        XCTAssertEqual(notification?.supersededNotificationIdentifiers, ["reconnect-needed:600"])
    }

    func testSmokeProbeOnlyRecoveryDoesNotAcknowledgeOrClearTheProblem() {
        // The smoke probe validates only the provider→resolver upstream leg. If it
        // succeeds but no real client query has resolved, neither the confirmation
        // nor the silent banner-clear fires — so we never tell the user "you're back"
        // (or drop the "reconnect" banner) while their device still isn't resolving.
        let now = Date(timeIntervalSince1970: 720)
        let probeAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnect-needed:600",
            lastDeliveredAt: now.addingTimeInterval(-90),
            unresolvedProblemNotificationID: "reconnect-needed:600",
            unresolvedProblemKind: .reconnectNeeded
        )
        let upstreamOnlyHealth = TunnelHealthSnapshot(
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: true
        )

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: upstreamOnlyHealth,
            history: history,
            now: now
        ))
        XCTAssertTrue(ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: Self.healthyAssessment,
            health: upstreamOnlyHealth,
            history: history,
            now: now
        ).isEmpty)
    }

    func testEncryptedFallbackOnlyRecoveryDoesNotAcknowledgeOrClearTheProblem() {
        // The encrypted Device-DNS safety net carried this query while the PRIMARY
        // resolver is still wedged. The tunnel records such successes under
        // `lastUpstreamSuccessAt` but NOT `lastPrimaryUpstreamSuccessAt`, so recovery
        // must not fire: neither the confirmation nor the silent banner-clear — every
        // subsequent query still depends on the fallback, so claiming "you're back"
        // (or dropping the "reconnect" banner) would be a lie.
        let now = Date(timeIntervalSince1970: 720)
        let fallbackSuccessAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnect-needed:600",
            lastDeliveredAt: now.addingTimeInterval(-90),
            unresolvedProblemNotificationID: "reconnect-needed:600",
            unresolvedProblemKind: .reconnectNeeded
        )
        // Fallback success postdates the problem and is fresh, but the primary signal
        // stays nil — only the safety net is carrying traffic.
        let fallbackOnlyHealth = TunnelHealthSnapshot(lastUpstreamSuccessAt: fallbackSuccessAt)

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: fallbackOnlyHealth,
            history: history,
            now: now
        ))
        XCTAssertTrue(ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: Self.healthyAssessment,
            health: fallbackOnlyHealth,
            history: history,
            now: now
        ).isEmpty)
    }

    func testPreOutageForwardingSuccessDoesNotAcknowledgeRecovery() {
        // A client query that succeeded shortly BEFORE the problem (id epoch 600) can
        // still be within the 120s freshness window, but it isn't evidence the outage
        // is over. Recovery must wait for a forwarding success that postdates the
        // problem — so neither the confirmation nor the banner-clear fires here.
        let now = Date(timeIntervalSince1970: 700)
        let staleSuccessAt = Date(timeIntervalSince1970: 595) // before the problem, still fresh
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnect-needed:600",
            lastDeliveredAt: now.addingTimeInterval(-90),
            unresolvedProblemNotificationID: "reconnect-needed:600",
            unresolvedProblemKind: .reconnectNeeded
        )
        let health = TunnelHealthSnapshot(lastPrimaryUpstreamSuccessAt: staleSuccessAt)

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: health,
            history: history,
            now: now
        ))
        XCTAssertTrue(ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: Self.healthyAssessment,
            health: health,
            history: history,
            now: now
        ).isEmpty)
    }

    func testSameSecondPreOutageSuccessDoesNotAcknowledgeRecovery() {
        // The problem id encodes a whole-second epoch (600), but the true event can be
        // anywhere in [600, 601). A forwarding success at 600.2 — earlier in that same
        // second — must NOT count as postdating it, so recovery requires reaching 601.
        let now = Date(timeIntervalSince1970: 660)
        let sameSecondSuccessAt = Date(timeIntervalSince1970: 600.2)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnect-needed:600",
            lastDeliveredAt: now.addingTimeInterval(-90),
            unresolvedProblemNotificationID: "reconnect-needed:600",
            unresolvedProblemKind: .reconnectNeeded
        )
        let health = TunnelHealthSnapshot(lastPrimaryUpstreamSuccessAt: sameSecondSuccessAt)

        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: health,
            history: history,
            now: now
        ))
        XCTAssertTrue(ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: Self.healthyAssessment,
            health: health,
            history: history,
            now: now
        ).isEmpty)
    }

    func testReconnectedAcknowledgementFiresOnceAndOnlyForADeliveredProblem() {
        let now = Date(timeIntervalSince1970: 700)
        let successAt = now.addingTimeInterval(-4)
        let recoveredHealth = TunnelHealthSnapshot(lastPrimaryUpstreamSuccessAt: successAt)

        // No problem was ever delivered → no recovery confirmation (auto-recoveries the
        // user never saw a warning for stay silent).
        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: recoveredHealth,
            history: .empty,
            now: now
        ))

        // Already acknowledged (lastDelivered is the reconnected id) → fires only once.
        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: recoveredHealth,
            history: ProtectionConnectivityNotificationHistory(
                lastDeliveredNotificationID: "reconnected:reconnect-needed:600",
                lastDeliveredAt: now.addingTimeInterval(-5),
                unresolvedProblemNotificationID: "reconnect-needed:600",
                unresolvedProblemKind: .reconnectNeeded
            ),
            now: now
        ))
    }

    func testResolvedProblemIdentifiersSkipMissingUnresolvedCases() {
        let now = Date(timeIntervalSince1970: 800)
        let successAt = now.addingTimeInterval(-2)
        let assessment = ProtectionConnectivityAssessment(
            severity: .healthy,
            primaryAction: .turnOff
        )
        let health = TunnelHealthSnapshot(
            lastDNSSmokeProbeAt: successAt,
            lastDNSSmokeProbeSucceeded: true,
            lastPrimaryUpstreamSuccessAt: successAt
        )

        XCTAssertTrue(ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: assessment,
            health: health,
            history: .empty,
            now: now
        ).isEmpty)

        XCTAssertTrue(ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: assessment,
            health: health,
            history: ProtectionConnectivityNotificationHistory(
                lastDeliveredNotificationID: "reconnected:network-unavailable:700",
                lastDeliveredAt: now.addingTimeInterval(-90),
                unresolvedProblemNotificationID: "network-unavailable:700",
                unresolvedProblemKind: .networkUnavailable
            ),
            now: now
        ).isEmpty)
    }

    func testResolvedProblemPostsReconnectedConfirmationAndClearsTheProblemBanner() {
        let now = Date(timeIntervalSince1970: 900)
        let successAt = now.addingTimeInterval(-2)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "network-unavailable:870",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "network-unavailable:870",
            unresolvedProblemKind: .networkUnavailable
        )
        let recoveredHealth = TunnelHealthSnapshot(lastPrimaryUpstreamSuccessAt: successAt)
        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: recoveredHealth,
            history: history,
            now: now
        )

        // Recovery now posts the confirmation AND still reports the problem banner to
        // clear — the two run together (the confirmation supersedes the banner too).
        XCTAssertEqual(notification?.kind, .reconnected)
        XCTAssertEqual(notification?.supersededNotificationIdentifiers, ["network-unavailable:870"])
        XCTAssertEqual(
            ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
                for: Self.healthyAssessment,
                health: recoveredHealth,
                history: history,
                now: now
            ),
            ["network-unavailable:870"]
        )
    }

    func testLegacyReconnectMarkerIsDemotedToSlowDNSOnce() {
        let suite = "test.protection.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keys = ProtectionConnectivityNotificationStore.DefaultsKeys(
            schemaVersion: "schemaVersion",
            unresolvedProblemKind: "unresolvedKind"
        )

        // An old build's outstanding slow-DNS banner was stored under the reconnect kind.
        defaults.set("reconnect-needed", forKey: keys.unresolvedProblemKind)

        XCTAssertTrue(ProtectionConnectivityNotificationStore.migrateLegacyKindSchemaIfNeeded(
            in: defaults,
            keys: keys
        ))
        // Demoted, not erased — recovery still has the marker to clear/acknowledge.
        XCTAssertEqual(defaults.string(forKey: keys.unresolvedProblemKind), "dns-slow")
        XCTAssertEqual(
            defaults.integer(forKey: keys.schemaVersion),
            ProtectionConnectivityNotificationStore.currentKindSchemaVersion
        )

        // Idempotent: once stamped, a genuine post-migration reconnect marker is untouched.
        defaults.set("reconnect-needed", forKey: keys.unresolvedProblemKind)
        XCTAssertFalse(ProtectionConnectivityNotificationStore.migrateLegacyKindSchemaIfNeeded(
            in: defaults,
            keys: keys
        ))
        XCTAssertEqual(defaults.string(forKey: keys.unresolvedProblemKind), "reconnect-needed")
    }

    func testKindSchemaMigrationLeavesNonReconnectMarkersUntouched() {
        let suite = "test.protection.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let keys = ProtectionConnectivityNotificationStore.DefaultsKeys(
            schemaVersion: "schemaVersion",
            unresolvedProblemKind: "unresolvedKind"
        )
        // network-unavailable was never affected by the slow-DNS kind change.
        defaults.set("network-unavailable", forKey: keys.unresolvedProblemKind)

        XCTAssertTrue(ProtectionConnectivityNotificationStore.migrateLegacyKindSchemaIfNeeded(
            in: defaults,
            keys: keys
        ))
        XCTAssertEqual(defaults.string(forKey: keys.unresolvedProblemKind), "network-unavailable")
    }

    func testReconnectNeededSupersedesDemotedLegacySlowDNSMarker() {
        // End-to-end: after migration demotes a legacy banner to .dnsSlow while keeping its
        // original "reconnect-needed:" id, a hard outage supersedes that exact id so the
        // stale banner is removed from Notification Center.
        let now = Date(timeIntervalSince1970: 1600)
        let eventAt = now.addingTimeInterval(-3)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "reconnect-needed:1500",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "reconnect-needed:1500", // id preserved by the demote
            unresolvedProblemKind: .dnsSlow                            // kind demoted by the migration
        )

        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: ProtectionConnectivityAssessment(severity: .needsReconnect, primaryAction: .reconnect),
            health: TunnelHealthSnapshot(
                lastDNSSmokeProbeAt: eventAt,
                lastDNSSmokeProbeSucceeded: false,
                lastNetworkChangeAt: now.addingTimeInterval(-30)
            ),
            history: history,
            now: now
        )

        XCTAssertEqual(notification?.kind, .reconnectNeeded)
        XCTAssertEqual(notification?.supersededNotificationIdentifiers, ["reconnect-needed:1500"])
    }

    private static var healthyAssessment: ProtectionConnectivityAssessment {
        ProtectionConnectivityAssessment(
            severity: .healthy,
            primaryAction: .turnOff
        )
    }
}
