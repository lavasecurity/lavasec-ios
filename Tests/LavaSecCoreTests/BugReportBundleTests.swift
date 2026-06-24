import XCTest
@testable import LavaSecCore

final class BugReportBundleTests: XCTestCase {
    func testIssueTypesUseFeedbackTopicSet() {
        XCTAssertEqual(BugReportIssueType.allCases.map(\.title), [
            "I can't visit a website",
            "VPN or filter doesn't work",
            "A Lava feature doesn't work",
            "I have a suggestion",
            "Something else"
        ])
    }

    func testIssueTypesMapToTriageKinds() {
        XCTAssertEqual(BugReportIssueType.websiteAccess.kind, .bug)
        XCTAssertEqual(BugReportIssueType.vpnOrFilterIssue.kind, .bug)
        XCTAssertEqual(BugReportIssueType.featureIssue.kind, .bug)
        XCTAssertEqual(BugReportIssueType.suggestion.kind, .suggestion)
        XCTAssertEqual(BugReportIssueType.other.kind, .other)
    }

    func testRequestBodyIncludesTriageKind() throws {
        let bundle = makeBundle(
            context: BugReportContext(issueType: .suggestion, details: "Please add a widget")
        )
        let body = bundle.makeRequestBody()
        XCTAssertEqual(body["kind"] as? String, "suggestion")
    }

    func testNormalizationStripsInvisibleAndControlCharacters() {
        let context = BugReportContext(
            issueType: .other,
            affectedSite: "exa\u{200B}mple.com",
            details: "Line one\nLine two\u{202E}reversed\u{0007}",
            contactEmail: "user\u{FEFF}@example.com"
        )

        // Zero-width space, bidi override, and bell control are removed; newline + text survive.
        XCTAssertEqual(context.normalizedAffectedSite, "example.com")
        XCTAssertEqual(context.normalizedDetails, "Line one\nLine tworeversed")
        XCTAssertEqual(context.normalizedContactEmail, "user@example.com")
    }

    func testSanitizeKeepsStandaloneEmojiButFlattensJoinedSequences() {
        // Standalone emoji, skin-tone modifiers, and flags are untouched (no invisible scalars).
        XCTAssertEqual(BugReportContext.sanitize("🚀"), "🚀")
        XCTAssertEqual(BugReportContext.sanitize("👍🏽"), "👍🏽")
        XCTAssertEqual(BugReportContext.sanitize("🇺🇸"), "🇺🇸")
        // ZWJ-joined sequences are flattened to their visible base scalars (joiner removed).
        XCTAssertEqual(BugReportContext.sanitize("👩\u{200D}👩\u{200D}👧"), "👩👩👧")
    }

    func testSanitizeStripsWordJoinerAndOtherInvisibleFormatScalars() {
        // Word joiner (U+2060) and other invisible format scalars must be stripped, not just
        // the specific zero-width set — otherwise blank-looking content submits hidden text.
        XCTAssertEqual(BugReportContext.sanitize("a\u{2060}b"), "ab")
        XCTAssertEqual(BugReportContext.sanitize("\u{2061}\u{2066}\u{206F}"), "")
        // ARABIC LETTER MARK (U+061C) is a bidi control and must be stripped too.
        XCTAssertEqual(BugReportContext.sanitize("a\u{061C}b"), "ab")
        XCTAssertEqual(BugReportContext.sanitize("\u{061C}"), "")
        // A zero-width joiner that is standalone, at an edge, or between ordinary characters
        // (incl. ASCII keycap bases, for which Unicode isEmoji is true) is invisible filler →
        // dropped, so it can't hide content and an all-invisible field normalizes to empty.
        XCTAssertEqual(BugReportContext.sanitize("\u{200D}"), "")
        XCTAssertEqual(BugReportContext.sanitize("a\u{200D}"), "a")
        XCTAssertEqual(BugReportContext.sanitize("a\u{200D}b"), "ab")
        XCTAssertEqual(BugReportContext.sanitize("1\u{200D}2"), "12")
        XCTAssertEqual(BugReportContext.sanitize("#\u{200D}*"), "#*")
        // Standalone variation selectors and soft hyphens are invisible → stripped.
        XCTAssertEqual(BugReportContext.sanitize("\u{FE0F}"), "")
        XCTAssertEqual(BugReportContext.sanitize("a\u{00AD}b"), "ab")
        // Tag characters (U+E0020–E007F) can ride along inside any emoji grapheme cluster, so
        // they are stripped unconditionally too — no invisible scalar survives.
        XCTAssertEqual(BugReportContext.sanitize("😀\u{E0061}\u{E0062}"), "😀")
        // Invisible scalars are removed even adjacent to emoji (joiner / selector flattened).
        XCTAssertEqual(BugReportContext.sanitize("👩\u{200D}👧"), "👩👧")
        XCTAssertEqual(BugReportContext.sanitize("❤\u{FE0F}"), "❤")
    }

    func testDetailsNormalizationEnforcesSharedInputLimit() {
        let longDetails = String(repeating: "a", count: BugReportInputLimits.details + 50)
        let context = BugReportContext(issueType: .other, details: longDetails)
        XCTAssertEqual(context.normalizedDetails.count, BugReportInputLimits.details)
    }

    func testSingleLineFieldsCollapseEmbeddedLineBreaks() {
        let context = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "example.com\nDetails: spoofed",
            details: "Line one\nLine two",
            contactEmail: "user\n@example.com"
        )

        // Single-line site + email collapse the newline to a space; multi-line details keep it.
        XCTAssertEqual(context.normalizedAffectedSite, "example.com Details: spoofed")
        XCTAssertEqual(context.normalizedContactEmail, "user @example.com")
        XCTAssertEqual(context.normalizedDetails, "Line one\nLine two")
        XCTAssertFalse(context.normalizedAffectedSite.contains("\n"))
        XCTAssertFalse(context.normalizedContactEmail?.contains("\n") ?? false)
        // The site value stays on a single line in the composed report text — it can't inject a
        // standalone "Details:" line; the only "Details:" line is the real one.
        XCTAssertTrue(context.userDescription.contains("Affected site/domain: example.com Details: spoofed"))
    }

    func testSingleLineFieldsCollapseUnicodeLineSeparators() {
        // U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR are line breaks too, so single-line
        // fields must collapse them just like \n — otherwise they reopen the line-injection path.
        let context = BugReportContext(
            issueType: .websiteAccess,
            affectedSite: "example.com\u{2028}Details: spoofed",
            contactEmail: "user\u{2029}@example.com"
        )
        XCTAssertEqual(context.normalizedAffectedSite, "example.com Details: spoofed")
        XCTAssertEqual(context.normalizedContactEmail, "user @example.com")

        // Multi-line details normalize every line-break variant (CRLF, lone CR, U+2028) to "\n".
        XCTAssertEqual(BugReportContext.sanitize("a\u{2028}b"), "a\nb")
        XCTAssertEqual(BugReportContext.sanitize("a\r\nb"), "a\nb")
        XCTAssertEqual(BugReportContext.sanitize("a\rb"), "a\nb")
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

    func testDebugLogParserKeepsNetworkRecoveryDiagnosticDetails() throws {
        // Mirrors what the tunnel now emits on release for the handoff/DNS-recovery
        // story — counts, reasons, and kinds only, never resolver addresses or
        // queried domains — so a Feedback log can show it without leaking anything.
        let jsonLines = """
        {"component":"tunnel","event":"device-dns-captured","timestamp":"2026-05-18T01:05:00Z","reason":"network-path-changed","count":"0","activeCount":"2"}
        {"component":"tunnel","event":"dns-smoke-probe-device-fallback","timestamp":"2026-05-18T01:05:01Z","reason":"network-settled","evidenceCount":"2","fallbackModeActive":"true"}
        {"component":"tunnel","event":"self-reconnect","timestamp":"2026-05-18T01:05:02Z","reason":"dns-wedged","attemptsInWindow":"1"}
        {"component":"tunnel","event":"dns-doq-connection-error","timestamp":"2026-05-18T01:05:03Z","endpoint":"dns.example:8853","phase":"failed","error":"POSIXErrorCode(rawValue: 54): Connection reset by peer","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].event, "device-dns-captured")
        XCTAssertEqual(entries[0].details["count"], "0")
        XCTAssertEqual(entries[0].details["activeCount"], "2")
        XCTAssertEqual(entries[1].details["evidenceCount"], "2")
        XCTAssertEqual(entries[1].details["fallbackModeActive"], "true")
        XCTAssertEqual(entries[2].event, "self-reconnect")
        XCTAssertEqual(entries[2].details["attemptsInWindow"], "1")
        XCTAssertEqual(entries[2].details["reason"], "dns-wedged")
        // DoQ connection failures are promoted to Release; the NWError reason and
        // phase must survive redaction (they distinguish failure modes during a
        // handoff) while a queried domain on the same entry is still stripped.
        XCTAssertEqual(entries[3].event, "dns-doq-connection-error")
        XCTAssertEqual(entries[3].details["phase"], "failed")
        XCTAssertEqual(entries[3].details["error"], "POSIXErrorCode(rawValue: 54): Connection reset by peer")
        XCTAssertEqual(entries[3].details["endpoint"], "dns.example:8853")
        XCTAssertNil(entries[3].details["privateDomain"])
    }

    func testDebugLogParserKeepsWedgeRecoveryDiagnosticDetails() throws {
        // The "said reconnect needed but never recovered" story: why a wedge was
        // not restarted (decision + gating booleans) and the in-place recovery
        // re-probe. Policy state only — no resolver address or queried domain.
        let jsonLines = """
        {"component":"tunnel","event":"self-reconnect-suppressed","timestamp":"2026-05-18T01:06:00Z","decision":"throttled","protectionEnabled":"true","onDemandConfirmed":"false","attemptsInWindow":"2","reason":"backed-off","privateDomain":"checkout.example"}
        {"component":"tunnel","event":"resolver-wedge-recovery","timestamp":"2026-05-18T01:06:30Z","reason":"backed-off","severity":"needs-reconnect","consecutiveUpstreamFailureCount":"5"}
        {"component":"tunnel","event":"dns-recovered","timestamp":"2026-05-18T01:06:35Z","reason":"backed-off","transport":"device-dns","durationMs":"5120","privateDomain":"checkout.example"}
        """

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(jsonLines.utf8), limit: 10)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].event, "self-reconnect-suppressed")
        XCTAssertEqual(entries[0].details["decision"], "throttled")
        XCTAssertEqual(entries[0].details["protectionEnabled"], "true")
        XCTAssertEqual(entries[0].details["onDemandConfirmed"], "false")
        XCTAssertEqual(entries[0].details["attemptsInWindow"], "2")
        XCTAssertEqual(entries[0].details["reason"], "backed-off")
        XCTAssertNil(entries[0].details["privateDomain"])
        XCTAssertEqual(entries[1].event, "resolver-wedge-recovery")
        XCTAssertEqual(entries[1].details["severity"], "needs-reconnect")
        XCTAssertEqual(entries[1].details["consecutiveUpstreamFailureCount"], "5")
        // The recovery counterpart: mechanism + how long the wedge lasted, with a
        // co-located queried domain still stripped.
        XCTAssertEqual(entries[2].event, "dns-recovered")
        XCTAssertEqual(entries[2].details["transport"], "device-dns")
        XCTAssertEqual(entries[2].details["durationMs"], "5120")
        XCTAssertNil(entries[2].details["privateDomain"])
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
                "Incident Summary",
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

    // MARK: - LAV-94 A: live-activity reconcile must not flood the report window

    func testDebugLogParserExcludesLiveActivityReconcileFromReportWindow() {
        // 14 reconciles + 2 incident events; the small window (limit 5) must keep the incident
        // events, not be flooded out by the high-frequency reconcile churn (LAV-94 A).
        var lines = [
            #"{"component":"tunnel","event":"self-reconnect","reason":"receive-failed","timestamp":"2026-06-22T00:00:00Z"}"#
        ]
        for index in 0..<14 {
            lines.append(
                #"{"component":"live-activity-controller","event":"reconcile","timestamp":"2026-06-22T00:00:\#(String(format: "%02d", index))Z"}"#
            )
        }
        lines.append(
            #"{"component":"tunnel","event":"resolver-wedge-recovery","reason":"covered-primary-recapture","timestamp":"2026-06-22T00:00:20Z"}"#
        )

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(lines.joined(separator: "\n").utf8), limit: 5)

        XCTAssertFalse(
            entries.contains { $0.component == "live-activity-controller" && $0.event == "reconcile" },
            "Reconcile churn must be excluded from the report window."
        )
        XCTAssertTrue(entries.contains { $0.event == "self-reconnect" })
        XCTAssertTrue(entries.contains { $0.event == "resolver-wedge-recovery" })
    }

    func testDebugLogParserExcludesLatencySpanChurnFromReportWindow() {
        // The QA/Debug-only resolver latency spans fire ~2 per DNS wire attempt; on a recovering
        // link they flood the window and evict the incident events (on-device QA replay 2026-06-22:
        // ~30 of 40 entries were latency-span pairs). The small window must keep the self-reconnect.
        var lines = [
            #"{"component":"tunnel","event":"self-reconnect","reason":"receive-failed","timestamp":"2026-06-22T00:00:00Z"}"#
        ]
        for index in 0..<14 {
            lines.append(
                #"{"component":"tunnel","event":"latency-span-begin","timestamp":"2026-06-22T00:00:\#(String(format: "%02d", index))Z"}"#
            )
            lines.append(
                #"{"component":"tunnel","event":"latency-span-end","details":{"durationMs":"8"},"timestamp":"2026-06-22T00:00:\#(String(format: "%02d", index))Z"}"#
            )
        }
        lines.append(
            #"{"component":"tunnel","event":"startTunnel-begin","timestamp":"2026-06-22T00:00:30Z"}"#
        )

        let entries = BugReportDebugLogEntry.parseJSONLines(Data(lines.joined(separator: "\n").utf8), limit: 5)

        XCTAssertFalse(
            entries.contains { $0.event == "latency-span-begin" || $0.event == "latency-span-end" },
            "Per-query latency-span churn must be excluded from the report window."
        )
        XCTAssertTrue(entries.contains { $0.event == "self-reconnect" })
        XCTAssertTrue(entries.contains { $0.event == "startTunnel-begin" })
    }

    // MARK: - LAV-94 B: redacted incident summary

    func testRequestBodyIncludesIncidentSummaryWhenDiagnosticsAreIncluded() throws {
        // Anchor to "now" so the self-reconnect timeline falls inside the attempt window the
        // summary prunes to (the bundle's `incident` uses the current clock).
        let networkChangedAt = Date().addingTimeInterval(-180)
        let reconnectAt = networkChangedAt.addingTimeInterval(120)
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                details: "Lava keeps reconnecting on its own.",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                lastFailureReason: "receive-failed",
                consecutiveUpstreamFailureCount: 2,
                lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(110),
                lastDNSSmokeProbeSucceeded: false,
                consecutiveDNSSmokeProbeFailureCount: 5,
                consecutiveRejectedSmokeResponseCount: 0,
                lastNetworkChangeAt: networkChangedAt,
                networkChangeCount: 3,
                resolverRuntimeResetCount: 1,
                lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(60)
            ),
            selfReconnectTimes: [reconnectAt, networkChangedAt.addingTimeInterval(30)]
        )

        let body = bundle.makeRequestBody()
        XCTAssertEqual(body["has_incident_summary"] as? Bool, true)
        let incident = try XCTUnwrap(body["incident"] as? [String: Any])
        XCTAssertEqual(incident["self_reconnect_count"] as? Int, 2)
        XCTAssertEqual(incident["consecutive_dns_smoke_probe_failure_count"] as? Int, 5)
        XCTAssertEqual(incident["consecutive_rejected_smoke_response_count"] as? Int, 0)
        XCTAssertEqual(incident["last_failure_reason"] as? String, "receive-failed")
        XCTAssertNotNil(incident["last_self_reconnect_at"])
        XCTAssertNotNil(incident["last_encrypted_fallback_success_at"])
        let times = try XCTUnwrap(incident["self_reconnect_times"] as? [String])
        XCTAssertEqual(times.count, 2)
        // Timeline is sorted ascending, so the last entry is the most recent self-reconnect.
        XCTAssertEqual(incident["last_self_reconnect_at"] as? String, times.last)
    }

    func testIncidentSummaryAbsentWithoutDiagnostics() {
        let bundle = makeBundle(
            context: BugReportContext(issueType: .vpnOrFilterIssue, includeDiagnostics: false),
            selfReconnectTimes: [Date(timeIntervalSinceReferenceDate: 800_720_000)]
        )

        let body = bundle.makeRequestBody()
        XCTAssertEqual(body["has_incident_summary"] as? Bool, false)
        XCTAssertNil(body["incident"], "No incident envelope is sent unless diagnostics are attached.")
    }

    func testIncidentSummaryHasNoContentOnAHealthyTunnel() {
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: []
        )
        XCTAssertFalse(incident.hasContent, "A clean snapshot with no failures or reconnects has nothing to report.")
    }

    func testIncidentSummaryCarriesNoResolvedDomains() throws {
        let bundle = makeBundle(
            context: BugReportContext(
                issueType: .vpnOrFilterIssue,
                affectedSite: "secret-site.example",
                includeDiagnostics: true
            ),
            health: TunnelHealthSnapshot(
                lastFailureReason: "receive-failed",
                consecutiveDNSSmokeProbeFailureCount: 3
            ),
            selfReconnectTimes: [Date(timeIntervalSinceReferenceDate: 800_720_000)]
        )

        let incident = try XCTUnwrap(bundle.makeRequestBody()["incident"] as? [String: Any])
        // The incident envelope is timestamps / counts / policy reasons only — never a queried
        // domain or browsing history (the data-minimization line, LAV-94 B).
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: incident), as: UTF8.self)
        XCTAssertFalse(serialized.contains("secret-site"))
        XCTAssertFalse(serialized.lowercased().contains("example"))
    }

    func testIncidentSummaryTimelineIsBounded() {
        let base = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let manyTimes = (0..<50).map { base.addingTimeInterval(Double($0)) }
        // `now` anchored to the last attempt so all 50 fall inside the prune window and the
        // bound (not the window) is what trims the timeline.
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(lastFailureReason: "receive-failed"),
            selfReconnectTimes: manyTimes,
            now: manyTimes.last!
        )
        XCTAssertEqual(incident.selfReconnectTimes.count, BugReportIncidentSummary.maxSelfReconnectTimes)
        // The cap keeps the MOST RECENT attempts.
        XCTAssertEqual(incident.lastSelfReconnectAt, manyTimes.last)
    }

    func testIncidentSummaryPrunesSelfReconnectsOutsideTheAttemptWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let recent = now.addingTimeInterval(-120)            // inside the 600s attempt window
        let stale = now.addingTimeInterval(-1_800)           // 30 min old — outside the window
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(lastFailureReason: "receive-failed"),
            selfReconnectTimes: [stale, recent],
            now: now
        )
        XCTAssertEqual(
            incident.selfReconnectTimes,
            [recent],
            "Only self-reconnects inside the attempt window are surfaced — the persisted store can hold older ones the tunnel hasn't pruned yet."
        )
        XCTAssertEqual(incident.selfReconnectCount, 1)
    }

    func testIncidentSummaryStaleOnlySelfReconnectDoesNotFlagAnIncident() {
        let now = Date(timeIntervalSinceReferenceDate: 800_720_000)
        // A clean tunnel whose ONLY "evidence" is a self-reconnect older than the window must
        // not report an incident — otherwise a report filed long after a one-off reconnect would
        // dishonestly set has_incident_summary (the Codex finding on #105).
        let incident = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [now.addingTimeInterval(-3_600)],
            now: now
        )
        XCTAssertTrue(incident.selfReconnectTimes.isEmpty)
        XCTAssertFalse(incident.hasContent)
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
        health: TunnelHealthSnapshot? = nil,
        selfReconnectTimes: [Date] = []
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
            debugLogEntries: debugLogEntries,
            selfReconnectTimes: selfReconnectTimes
        )
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
