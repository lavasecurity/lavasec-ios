import XCTest
@testable import LavaSecCore

final class BugReportBundleTests: XCTestCase {
    func testIssueTypesUseFeedbackTopicSet() {
        XCTAssertEqual(BugReportIssueType.allCases.map(\.title), [
            "I can't visit a website",
            "VPN or filter doesn't work",
            "A Lava feature doesn't work",
            "Something else"
        ])
    }

    func testRequestBodyOmitsOptionalDiagnosticsByDefault() throws {
        let bundle = makeBundle()
        let body = bundle.makeRequestBody()

        XCTAssertEqual(body["include_optional_diagnostics"] as? Bool, false)
        XCTAssertEqual(body["include_recent_dns_events"] as? Bool, false)
        XCTAssertNotNil(body["report_id"])
        XCTAssertNotNil(body["user_description"])
        XCTAssertNil(body["recent_dns_events"])
        XCTAssertNil(body["app"])
        XCTAssertNil(body["device"])
        XCTAssertNil(body["vpn"])
        XCTAssertNil(body["filters"])
        XCTAssertNil(body["diagnostics"])
        XCTAssertNil(body["debug_log"])
    }

    func testRequestBodyExcludesRecentDomainEventsWhenDiagnosticsAreIncluded() throws {
        var diagnostics = DiagnosticsStore(startedAt: Date(timeIntervalSinceReferenceDate: 100))
        diagnostics.record(
            domain: "private-bank.example",
            decision: FilterDecision(action: .block, reason: .blocklist),
            keepDomainHistory: true
        )
        diagnostics.record(domain: "weather.example", decision: .defaultAllow, keepDomainHistory: true)

        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .websiteAccess,
                affectedSite: "checkout.example",
                details: "Checkout would not load after protection turned on.",
                includeDiagnostics: true
            ),
            diagnostics: diagnostics
        )
        let body = bundle.makeRequestBody()
        let json = try jsonString(body)

        XCTAssertEqual(body["include_optional_diagnostics"] as? Bool, true)
        XCTAssertEqual(body["include_recent_dns_events"] as? Bool, false)
        XCTAssertNil(body["recent_dns_events"])
        XCTAssertFalse(json.contains("private-bank.example"))
        XCTAssertFalse(json.contains("weather.example"))

        let diagnosticsBody = try XCTUnwrap(body["diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnosticsBody["blocked_count"] as? Int, 1)
        XCTAssertEqual(diagnosticsBody["allowed_count"] as? Int, 1)
        XCTAssertEqual(diagnosticsBody["has_domain_history"] as? Bool, true)
    }

    func testBugReportDoesNotIncludeNetworkActivityLogByDefault() throws {
        let bundle = makeBundle()
        let body = bundle.makeRequestBody()
        let json = try jsonString(body)

        XCTAssertNil(body["network_activity_log"])
        XCTAssertFalse(json.contains("network_activity_log"))
        XCTAssertFalse(json.contains("eventLine"))
        XCTAssertFalse(json.contains("lavaStateLine"))
    }

    func testRequestBodyDoesNotIncludeCustomBlocklistURLs() throws {
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "A custom blocklist stopped working.",
                includeDiagnostics: true
            ),
            filters: BugReportFilterSummary(
                catalogVersion: "20260526T000000Z",
                enabledListIDs: ["blocklistproject-basic", "custom-sensitive"],
                snapshotVersion: "snapshot-456",
                compiledRuleCount: 20,
                blocklistRuleCount: 18,
                customBlocklistCount: 1,
                enabledCustomBlocklistCount: 1
            )
        )

        let body = bundle.makeRequestBody()
        let json = try jsonString(body)
        let filters = try XCTUnwrap(body["filters"] as? [String: Any])

        XCTAssertEqual(filters["custom_blocklist_count"] as? Int, 1)
        XCTAssertEqual(filters["enabled_custom_blocklist_count"] as? Int, 1)
        XCTAssertFalse(json.contains("sensitive.example.com"))
        XCTAssertFalse(json.contains("private-list.txt"))
        XCTAssertFalse(json.contains("https://"))
    }

    func testRequestBodyIncludesAffectedSiteFilterDecisionForUserProvidedSite() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "linkedin.com", matchesSubdomains: true)
        let snapshot = FilterSnapshot(blockRules: blockRules)
        let context = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "https://www.linkedin.com/feed/",
            details: "LinkedIn would not load.",
            includeDiagnostics: true
        )
        let decision = try XCTUnwrap(BugReportAffectedSiteFilterDecision.make(
            rawAffectedSite: context.normalizedAffectedSite,
            snapshot: snapshot
        ))
        let bundle = makeBundle(context: context, affectedSiteDecision: decision)

        let body = bundle.makeRequestBody()
        let filters = try XCTUnwrap(body["filters"] as? [String: Any])

        XCTAssertEqual(filters["affected_site_domain"] as? String, "www.linkedin.com")
        XCTAssertEqual(filters["affected_site_filter_action"] as? String, "block")
        XCTAssertEqual(filters["affected_site_filter_reason"] as? String, "blocklist")
    }

    func testDebugLogParserDropsPotentiallyIdentifyingDetails() throws {
        let jsonLines = """
        {"component":"app","event":"enable-begin","timestamp":"2026-05-18T01:02:03Z","vpnStatus":"connected","arguments":"--token secret","providerConfiguration":"private config","resolver":"Google Public DNS"}
        {"component":"tunnel","event":"network-path-changed","timestamp":"2026-05-18T01:03:03Z","kind":"wifi","status":"satisfied","options":"launch options"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].component, "app")
        XCTAssertEqual(entries[0].event, "enable-begin")
        XCTAssertEqual(entries[0].details["vpnStatus"], "connected")
        XCTAssertEqual(entries[0].details["resolver"], "Google Public DNS")
        XCTAssertNil(entries[0].details["arguments"])
        XCTAssertNil(entries[0].details["providerConfiguration"])
        XCTAssertEqual(entries[1].details["kind"], "wifi")
        XCTAssertNil(entries[1].details["options"])
    }

    func testDebugLogParserKeepsSafeQAConnectivityDetails() throws {
        let jsonLines = """
        {"component":"tunnel","event":"qa-connectivity-assessment","timestamp":"2026-05-18T01:04:03Z","severity":"needsReconnect","primaryAction":"reconnect","lastFailureReason":"timeout","lastResolverTransport":"plainDNS","upstreamSuccessCount":"9","upstreamFailureCount":"3","upstreamTimeoutCount":"3","dnsSmokeProbeFailureCount":"1","deviceDNSFallbackActivationCount":"0","resolverRuntimeResetCount":"2","lastUpstreamFailureAt":"2026-05-18T01:04:00Z","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].details["severity"], "needsReconnect")
        XCTAssertEqual(entries[0].details["primaryAction"], "reconnect")
        XCTAssertEqual(entries[0].details["lastFailureReason"], "timeout")
        XCTAssertEqual(entries[0].details["lastResolverTransport"], "plainDNS")
        XCTAssertEqual(entries[0].details["upstreamFailureCount"], "3")
        XCTAssertEqual(entries[0].details["lastUpstreamFailureAt"], "2026-05-18T01:04:00Z")
        XCTAssertNil(entries[0].details["privateDomain"])
    }

    func testDebugLogParserKeepsLatencySpanDetails() throws {
        let jsonLines = """
        {"component":"tunnel","event":"latency-span-end","timestamp":"2026-06-12T10:00:00Z","operationID":"op-turn-on-0001","operationKind":"turnOn","spanID":"span-network-settings","parentSpanID":"span-start-tunnel","spanName":"tunnel.setNetworkSettings","spanEvent":"end","durationMs":"842","sequence":"7","status":"ok","errorKind":"none","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].details["operationID"], "op-turn-on-0001")
        XCTAssertEqual(entries[0].details["operationKind"], "turnOn")
        XCTAssertEqual(entries[0].details["spanID"], "span-network-settings")
        XCTAssertEqual(entries[0].details["parentSpanID"], "span-start-tunnel")
        XCTAssertEqual(entries[0].details["spanName"], "tunnel.setNetworkSettings")
        XCTAssertEqual(entries[0].details["spanEvent"], "end")
        XCTAssertEqual(entries[0].details["durationMs"], "842")
        XCTAssertEqual(entries[0].details["sequence"], "7")
        XCTAssertEqual(entries[0].details["status"], "ok")
        XCTAssertEqual(entries[0].details["errorKind"], "none")
        XCTAssertNil(entries[0].details["privateDomain"])
    }

    func testPreviewSectionsExplainEachIncludedBundlePart() {
        let bundle = makeBundle(
            debugLogEntries: [
                BugReportDebugLogEntry(
                    component: "tunnel",
                    event: "startTunnel-ready",
                    timestamp: "2026-05-18T01:02:03Z",
                    details: [:]
                )
            ]
        )

        let sections = bundle.previewSections
        let titles = sections.map(\.title)

        XCTAssertEqual(
            titles,
            [
                "What happened",
                "App & Device",
                "VPN Status",
                "Tunnel Lifecycle Log",
                "Network & Resolver Health",
                "Filter Snapshot",
                "Local Activity Summary"
            ]
        )
        XCTAssertTrue(sections.allSatisfy { !$0.purpose.isEmpty })
        XCTAssertTrue(sections.allSatisfy { !$0.items.isEmpty })
    }

    func testBugReportIncludesCurrentDeviceDNSFallbackContext() throws {
        let activatedAt = Date(timeIntervalSinceReferenceDate: 800_720_030)
        let probeAt = Date(timeIntervalSinceReferenceDate: 800_720_020)
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Device DNS fallback is active.",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                startedAt: Date(timeIntervalSinceReferenceDate: 10),
                updatedAt: Date(timeIntervalSinceReferenceDate: 20),
                networkKind: .wifi,
                lastResolverAddress: "192.168.1.1",
                lastFailureReason: nil,
                upstreamSuccessCount: 9,
                upstreamFailureCount: 1,
                lastResolverTransport: .deviceDNS,
                deviceDNSUnavailableCount: 2,
                lastDNSSmokeProbeAt: probeAt,
                lastDNSSmokeProbeSucceeded: false,
                dnsSmokeProbeFailureCount: 1,
                deviceDNSFallbackModeActive: true,
                lastDeviceDNSFallbackActivatedAt: activatedAt,
                deviceDNSFallbackActivationCount: 1
            )
        )

        let body = bundle.makeRequestBody()
        let vpn = try XCTUnwrap(body["vpn"] as? [String: Any])
        let section: BugReportPreviewSection = try XCTUnwrap(
            bundle.previewSections.first { $0.id == "network_resolver" }
        )
        let itemIDs = Set(section.items.map(\.id))

        XCTAssertEqual(vpn["device_dns_fallback_mode_active"] as? Bool, true)
        XCTAssertEqual(vpn["last_resolver_transport"] as? String, "device-dns")
        XCTAssertEqual(vpn["last_dns_smoke_probe_succeeded"] as? Bool, false)
        XCTAssertEqual(vpn["device_dns_unavailable_count"] as? Int, 2)
        XCTAssertNotNil(vpn["last_device_dns_fallback_activated_at"])
        XCTAssertNotNil(vpn["last_dns_smoke_probe_at"])
        XCTAssertTrue(itemIDs.contains("device_dns_fallback_active"))
        XCTAssertTrue(itemIDs.contains("last_resolver_transport"))
        XCTAssertTrue(itemIDs.contains("device_dns_unavailable"))
    }

    func testSubmissionPolicyKeepsPreparedSnapshotWhenContextMatches() {
        let context = BugReportContext(
            issueType: .vpnOrFilterIssue,
            affectedSite: "",
            details: "Lava stopped resolving while the phone still had internet.",
            contactEmail: nil,
            includeDiagnostics: true
        )
        let preparedDraft = makeBundle(
            reportID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-9aaa-aaaaaaaaaaaa")!,
            context: context,
            vpnStatus: "connected"
        )
        var didBuildFreshBundle = false

        let bundle = BugReportSubmissionBundlePolicy.bundleToSubmit(
            draft: preparedDraft,
            currentContext: context
        ) {
            didBuildFreshBundle = true
            return makeBundle(
                reportID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb")!,
                context: context,
                vpnStatus: "disconnected"
            )
        }

        XCTAssertFalse(didBuildFreshBundle)
        XCTAssertEqual(bundle.reportID, preparedDraft.reportID)
        XCTAssertEqual(bundle.vpn.status, "connected")
    }

    func testSubmissionPolicyRebuildsSnapshotWhenContextChanged() {
        let preparedContext = BugReportContext(
            issueType: .vpnOrFilterIssue,
            details: "Old details",
            includeDiagnostics: true
        )
        let currentContext = BugReportContext(
            issueType: .vpnOrFilterIssue,
            details: "Updated details",
            includeDiagnostics: true
        )
        let preparedDraft = makeBundle(
            reportID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-9aaa-aaaaaaaaaaaa")!,
            context: preparedContext,
            vpnStatus: "connected"
        )
        let freshBundle = makeBundle(
            reportID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb")!,
            context: currentContext,
            vpnStatus: "disconnected"
        )

        let bundle = BugReportSubmissionBundlePolicy.bundleToSubmit(
            draft: preparedDraft,
            currentContext: currentContext
        ) {
            freshBundle
        }

        XCTAssertEqual(bundle.reportID, freshBundle.reportID)
        XCTAssertEqual(bundle.context, currentContext)
        XCTAssertEqual(bundle.vpn.status, "disconnected")
    }

    private func makeBundle(
        reportID: UUID = UUID(uuidString: "12345678-1234-4234-9234-123456789abc")!,
        context: BugReportContext = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "checkout.example",
            details: "Checkout would not load after protection turned on.",
            contactEmail: nil
        ),
        vpnStatus: String = "connected",
        affectedSiteDecision: BugReportAffectedSiteFilterDecision? = nil,
        filters: BugReportFilterSummary? = nil,
        diagnostics: DiagnosticsStore = DiagnosticsStore(startedAt: Date(timeIntervalSinceReferenceDate: 100)),
        debugLogEntries: [BugReportDebugLogEntry] = [],
        health: TunnelHealthSnapshot? = nil
    ) -> BugReportBundle {
        BugReportBundle(
            reportID: reportID,
            context: context,
            app: BugReportAppSnapshot(version: "1.2.3", build: "45"),
            device: BugReportDeviceSnapshot(
                iosVersion: "iOS 18.5",
                deviceFamily: "Phone",
                locale: "en_US"
            ),
            vpn: BugReportVPNSnapshot(
                status: vpnStatus,
                resolverPreset: "Google Public DNS",
                health: health ?? TunnelHealthSnapshot(
                    startedAt: Date(timeIntervalSinceReferenceDate: 10),
                    updatedAt: Date(timeIntervalSinceReferenceDate: 20),
                    networkKind: .wifi,
                    lastResolverAddress: "8.8.8.8",
                    lastFailureReason: "timeout",
                    cacheHitCount: 7,
                    cacheMissCount: 3,
                    coalescedQueryCount: 2,
                    upstreamSuccessCount: 9,
                    upstreamFailureCount: 1,
                    lastResolverTransport: .plainDNS,
                    upstreamTimeoutCount: 1,
                    tcpFallbackAttemptCount: 1,
                    tcpFallbackSuccessCount: 1,
                    networkChangeCount: 2,
                    resolverRuntimeResetCount: 1
                )
            ),
            filters: filters ?? BugReportFilterSummary(
                catalogVersion: "20260518T000000Z",
                enabledListIDs: ["blocklistproject-basic"],
                snapshotVersion: "snapshot-123",
                compiledRuleCount: 1200,
                blocklistRuleCount: 1180,
                affectedSiteDecision: affectedSiteDecision
            ),
            diagnostics: diagnostics,
            localHistoryEnabled: false,
            debugLogEntries: debugLogEntries
        )
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
