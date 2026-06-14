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
                primaryAction: .turnOff,
                title: "Using Device DNS",
                subtitle: "Network DNS rules changed."
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
                primaryAction: .turnOff,
                title: "Network Lost",
                subtitle: "No internet path is available."
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
                primaryAction: .reconnect,
                title: "Reconnect Needed",
                subtitle: "DNS smoke test failed."
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
            primaryAction: .turnOff,
            title: "Using Device DNS",
            subtitle: "Network DNS rules changed."
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
                primaryAction: .turnOff,
                title: "Network Lost",
                subtitle: "No internet path is available."
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
                primaryAction: .turnOff,
                title: "Network Lost",
                subtitle: "No internet path is available."
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
                primaryAction: .turnOff,
                title: "Network Lost",
                subtitle: "No internet path is available."
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

    func testResolvedProblemDoesNotSurfaceReconnectedAcknowledgementAfterVerifiedDNSSuccess() {
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
                lastDNSSmokeProbeAt: successAt,
                lastDNSSmokeProbeSucceeded: true,
                lastNetworkChangeAt: now.addingTimeInterval(-20)
            ),
            history: history,
            now: now
        )

        XCTAssertNil(notification)
    }

    func testResolvedProblemIdentifiersSkipMissingUnresolvedCases() {
        let now = Date(timeIntervalSince1970: 800)
        let successAt = now.addingTimeInterval(-2)
        let assessment = ProtectionConnectivityAssessment(
            severity: .healthy,
            primaryAction: .turnOff,
            title: "Protected",
            subtitle: "Filtering happens locally on this phone"
        )
        let health = TunnelHealthSnapshot(
            lastDNSSmokeProbeAt: successAt,
            lastDNSSmokeProbeSucceeded: true,
            lastUpstreamSuccessAt: successAt
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

    func testResolvedProblemIdentifiersReturnPreviousProblemWithoutSurfacingNotification() {
        let now = Date(timeIntervalSince1970: 900)
        let successAt = now.addingTimeInterval(-2)
        let history = ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: "network-unavailable:870",
            lastDeliveredAt: now.addingTimeInterval(-20),
            unresolvedProblemNotificationID: "network-unavailable:870",
            unresolvedProblemKind: .networkUnavailable
        )
        let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: Self.healthyAssessment,
            health: TunnelHealthSnapshot(
                lastDNSSmokeProbeAt: successAt,
                lastDNSSmokeProbeSucceeded: true
            ),
            history: history,
            now: now
        )

        XCTAssertNil(notification)
        XCTAssertEqual(
            ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
                for: Self.healthyAssessment,
                health: TunnelHealthSnapshot(
                    lastDNSSmokeProbeAt: successAt,
                    lastDNSSmokeProbeSucceeded: true
                ),
                history: history,
                now: now
            ),
            ["network-unavailable:870"]
        )
    }

    private static var healthyAssessment: ProtectionConnectivityAssessment {
        ProtectionConnectivityAssessment(
            severity: .healthy,
            primaryAction: .turnOff,
            title: "Protected",
            subtitle: "Filtering happens locally on this phone"
        )
    }
}
