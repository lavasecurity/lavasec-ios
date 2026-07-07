import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class GuardStepHealthPolicyTests: XCTestCase {
    func testDNSIsInactiveWhenProtectionIsOff() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: false,
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(lastResolverTransport: .dnsOverHTTPS),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(status, .inactive)
    }

    func testDNSIsInactiveWhenDeviceDNSIsSelected() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .device,
            health: TunnelHealthSnapshot(lastResolverTransport: .deviceDNS),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(status, .inactive)
    }

    func testDNSIsHealthyWhenConfiguredDoHResolverIsActive() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(lastResolverTransport: .dnsOverHTTPS),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(status, .healthy)
    }

    func testDNSDoesNotTreatStaleNonDeviceTransportMismatchAsIssue() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(
                upstreamSuccessCount: 1,
                lastResolverTransport: .plainDNS
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(status, .healthy)
    }

    func testDNSIssueBeatsNativeFallbackWhileProtectionIsOn() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(
                lastFailureReason: "timeout",
                lastResolverTransport: .deviceDNS,
                lastUpstreamFailureAt: Date(timeIntervalSinceReferenceDate: 800_720_000)
            ),
            connectivitySeverity: .needsReconnect
        )

        XCTAssertEqual(status, .issue)
    }

    func testDNSIsIssueWhenResolverIsSlow() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .quad9SecureDoT,
            health: TunnelHealthSnapshot(lastResolverTransport: .dnsOverTLS),
            connectivitySeverity: .dnsSlow
        )

        XCTAssertEqual(status, .issue)
    }

    func testDNSStaysHealthyWhenOnlyLastQueryUsedDeviceDNSFallback() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(
                lastResolverTransport: .deviceDNS,
                deviceDNSFallbackAttemptCount: 1,
                deviceDNSFallbackSuccessCount: 1
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(status, .healthy)
    }

    func testDNSIsInactiveWhenFallbackStateIsActive() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(lastResolverTransport: .dnsOverHTTPS),
            connectivitySeverity: .usingDeviceDNSFallback
        )

        XCTAssertEqual(status, .inactive)
    }

    func testDNSDetailShowsDeviceFallbackWhenFallbackIsActive() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(lastResolverTransport: .deviceDNS),
            connectivitySeverity: .usingDeviceDNSFallback
        )

        XCTAssertEqual(detail, "Device DNS fallback")
    }

    func testDNSDetailKeepsConfiguredResolverWhenOnlyLastQueryUsedDeviceDNSFallback() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(
                lastResolverTransport: .deviceDNS,
                deviceDNSFallbackAttemptCount: 1,
                deviceDNSFallbackSuccessCount: 1
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(detail, "Google (DoH)")
    }

    func testDNSStaysHealthyWhenRawFallbackFlagIsStaleButConnectivityIsHealthy() {
        let status = GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: true,
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(
                lastResolverTransport: .deviceDNS,
                deviceDNSFallbackModeActive: true
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(status, .healthy)
    }

    func testDNSDetailKeepsConfiguredResolverWhenRawFallbackFlagIsStale() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(
                lastResolverTransport: .deviceDNS,
                deviceDNSFallbackModeActive: true
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(detail, "Google (DoH)")
    }

    func testDNSDetailKeepsConfiguredResolverWhenReconnectIsNeededWithoutFallback() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .googleDoH,
            health: TunnelHealthSnapshot(lastResolverTransport: .dnsOverHTTPS),
            connectivitySeverity: .needsReconnect
        )

        XCTAssertEqual(detail, "Google (DoH)")
    }

    func testDNSDetailAnnotatesDoH3WhenHTTP3WasNegotiatedWithTheConfiguredResolver() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .quad9SecureDoH,
            health: TunnelHealthSnapshot(
                lastResolverAddress: "doh:https://dns.quad9.net/dns-query",
                lastResolverTransport: .dnsOverHTTPS,
                lastDoHHTTPVersion: "h3"
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(detail, "Quad9 (DoH3)")
    }

    func testDNSDetailKeepsDoHAnnotationForNonHTTP3Negotiations() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .quad9SecureDoH,
            health: TunnelHealthSnapshot(
                lastResolverAddress: "doh:https://dns.quad9.net/dns-query",
                lastResolverTransport: .dnsOverHTTPS,
                lastDoHHTTPVersion: "h2"
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(detail, "Quad9 (DoH)")
    }

    func testDNSDetailNeverBorrowsAnObservationFromAnotherResolver() {
        // The h3 observation belongs to Cloudflare; the configured resolver
        // is Quad9. The label must stay un-annotated until Quad9 negotiates.
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .quad9SecureDoH,
            health: TunnelHealthSnapshot(
                lastResolverAddress: "doh:https://cloudflare-dns.com/dns-query",
                lastResolverTransport: .dnsOverHTTPS,
                lastDoHHTTPVersion: "h3"
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(detail, "Quad9 (DoH)")
    }

    func testDNSDetailStartsUnannotatedBeforeAnyObservation() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .quad9SecureDoH,
            health: TunnelHealthSnapshot(lastResolverTransport: .dnsOverHTTPS),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(detail, "Quad9 (DoH)")
    }

    func testDNSDetailDoesNotAnnotateDoTPresetWithStaleDoHVersion() {
        let detail = GuardStepHealthPolicy.dnsDetail(
            configuredResolver: .cloudflareDoT,
            health: TunnelHealthSnapshot(
                lastResolverAddress: "doh:https://cloudflare-dns.com/dns-query",
                lastResolverTransport: .dnsOverTLS,
                lastDoHHTTPVersion: "h3"
            ),
            connectivitySeverity: .healthy
        )

        XCTAssertEqual(detail, "Cloudflare (DoT)")
    }

    func testFiltersAreInactiveWhenProtectionIsOff() {
        XCTAssertEqual(
            GuardStepHealthPolicy.filterStatus(
                isProtectionActive: false,
                filtersConfigured: true,
                hasFilterIssue: false,
                filterSnapshotUsable: true
            ),
            .inactive
        )
    }

    func testFiltersAreInactiveWhenNoLocalBlockingRulesAreConfigured() {
        XCTAssertEqual(
            GuardStepHealthPolicy.filterStatus(
                isProtectionActive: true,
                filtersConfigured: false,
                hasFilterIssue: false,
                filterSnapshotUsable: false
            ),
            .inactive
        )
    }

    func testFiltersAreHealthyWhenConfiguredAndUsable() {
        XCTAssertEqual(
            GuardStepHealthPolicy.filterStatus(
                isProtectionActive: true,
                filtersConfigured: true,
                hasFilterIssue: false,
                filterSnapshotUsable: true
            ),
            .healthy
        )
    }

    func testFiltersStayHealthyWhenConfiguredRulesHaveNotLoadedYet() {
        XCTAssertEqual(
            GuardStepHealthPolicy.filterStatus(
                isProtectionActive: true,
                filtersConfigured: true,
                hasFilterIssue: false,
                filterSnapshotUsable: false,
                filterSnapshotLoadComplete: false
            ),
            .healthy
        )
    }

    func testFiltersShowIssueWhenConfiguredRulesLoadedButUnusable() {
        XCTAssertEqual(
            GuardStepHealthPolicy.filterStatus(
                isProtectionActive: true,
                filtersConfigured: true,
                hasFilterIssue: false,
                filterSnapshotUsable: false,
                filterSnapshotLoadComplete: true
            ),
            .issue
        )
    }

    func testFilterIssueBeatsConfiguredFiltersWhileProtectionIsOn() {
        XCTAssertEqual(
            GuardStepHealthPolicy.filterStatus(
                isProtectionActive: true,
                filtersConfigured: true,
                hasFilterIssue: true,
                filterSnapshotUsable: true
            ),
            .issue
        )
    }

    func testLinkIsRedWhenEitherNeighborHasAnIssue() {
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.issue, .healthy), .issue)
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.healthy, .issue), .issue)
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.issue, .inactive), .issue)
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.issue, .issue), .issue)
    }

    // A lone grey (inactive) step is a passthrough that still carries traffic,
    // so its connectors stay green when the other neighbor is active.
    func testLinkStaysGreenForLoneInactivePassthroughStep() {
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.inactive, .healthy), .healthy)
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.healthy, .inactive), .healthy)
    }

    // Both neighbors inactive means the whole pipeline is off, so the bar greys
    // out with the steps rather than implying an active link.
    func testLinkIsGreyOnlyWhenBothNeighborsAreInactive() {
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.inactive, .inactive), .inactive)
    }

    func testLinkIsGreenWhenBothNeighborsAreHealthy() {
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.healthy, .healthy), .healthy)
    }

    // The original bug: a healthy DNS step sitting above a failing filters step
    // must color the connector between them red, not green.
    func testLinkBetweenHealthyDNSAndFilterIssueIsRed() {
        XCTAssertEqual(GuardFlowStepStatus.linkStatus(.healthy, .issue), .issue)
    }
}
