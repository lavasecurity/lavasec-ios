import Foundation

/// Coarse classification used by triage to separate defects from product ideas.
/// Sent to the backend alongside the report so the promoter can label the Linear
/// issue (`[bug]` / `[suggestion]` / `[other]`) and the triage agent can route it.
public enum BugReportIssueKind: String, Codable, Sendable {
    case bug
    case suggestion
    case other
}

public enum BugReportIssueType: String, CaseIterable, Codable, Identifiable, Sendable {
    // Bug topics first, then the suggestion topic, then a true catch-all "other".
    // Order here is the order shown in the feedback topic picker (allCases).
    case websiteAccess
    case vpnOrFilterIssue
    case featureIssue
    case suggestion
    case other

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .websiteAccess:
            "I can't visit a website"
        case .vpnOrFilterIssue:
            "VPN or filter doesn't work"
        case .featureIssue:
            "A Lava feature doesn't work"
        case .suggestion:
            "I have a suggestion"
        case .other:
            "Something else"
        }
    }

    public var kind: BugReportIssueKind {
        switch self {
        case .websiteAccess, .vpnOrFilterIssue, .featureIssue:
            .bug
        case .suggestion:
            .suggestion
        case .other:
            .other
        }
    }
}

/// Shared length limits for the free-text bug-report fields. Both the UI (counter
/// + input truncation) and the bundle normalization read these so the limit shown
/// to the user is exactly the limit enforced on submission (UR-29).
public enum BugReportInputLimits {
    public static let affectedSite = 300
    public static let details = 5_000
    public static let contactEmail = 320
}

public struct BugReportContext: Equatable, Codable, Sendable {
    public var issueType: BugReportIssueType
    public var affectedSite: String
    public var details: String
    public var contactEmail: String?
    public var includeDiagnostics: Bool

    public init(
        issueType: BugReportIssueType = .other,
        affectedSite: String = "",
        details: String = "",
        contactEmail: String? = nil,
        includeDiagnostics: Bool = false
    ) {
        self.issueType = issueType
        self.affectedSite = affectedSite
        self.details = details
        self.contactEmail = contactEmail
        self.includeDiagnostics = includeDiagnostics
    }

    public var normalizedAffectedSite: String {
        // Single-line field: collapse any embedded line breaks so a pasted value can't inject a
        // fake "Details:"/"Issue:" line into the composed userDescription (UR-29).
        Self.trim(affectedSite, maxLength: BugReportInputLimits.affectedSite, allowsLineBreaks: false)
    }

    public var normalizedDetails: String {
        Self.trim(details, maxLength: BugReportInputLimits.details, allowsLineBreaks: true)
    }

    public var normalizedContactEmail: String? {
        guard let contactEmail else {
            return nil
        }

        // Single-line field: no embedded line breaks.
        let trimmed = Self.trim(contactEmail, maxLength: BugReportInputLimits.contactEmail, allowsLineBreaks: false)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var userDescription: String {
        var lines = ["Issue: \(issueType.title)"]

        if !normalizedAffectedSite.isEmpty {
            lines.append("Affected site/domain: \(normalizedAffectedSite)")
        }

        if !normalizedDetails.isEmpty {
            lines.append("Details: \(normalizedDetails)")
        }

        return lines.joined(separator: "\n")
    }

    private static func trim(_ value: String, maxLength: Int, allowsLineBreaks: Bool) -> String {
        let trimmed = Self.sanitize(value, allowsLineBreaks: allowsLineBreaks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else {
            return trimmed
        }

        return String(trimmed.prefix(maxLength))
    }

    /// Strip control and invisible characters from free-text input before it is stored or
    /// transmitted. These are invisible in the text field but can smuggle hidden content or
    /// visually reorder text that later reaches the triage tooling, so normalizing here keeps
    /// what we send legible and is a first line of defense alongside the server-side
    /// sanitization (UR-29).
    ///
    /// Every invisible scalar is removed unconditionally — no scalar that doesn't render on its
    /// own survives, so nothing hidden can ride along inside an otherwise-visible string and an
    /// all-invisible field normalizes to empty. The deliberate trade-off for a diagnostic field
    /// is that multi-scalar emoji that rely on joiners/selectors/tags are flattened to their
    /// visible base scalars (👩‍👧 → 👩👧, 🏴 tag flags → 🏴, ❤️ → ❤); standalone emoji, skin-tone
    /// modifiers, and regional-indicator flags are unaffected.
    ///
    /// `allowsLineBreaks` is false for single-line fields (affected site, contact email): every
    /// line break — including the Unicode line/paragraph separators (U+2028 / U+2029) and NEL,
    /// not just `\n` — and tabs are collapsed to a space so a pasted value can't inject extra
    /// lines into the structured report text. Multi-line Details keeps its line breaks (all
    /// normalized to `\n`).
    static func sanitize(_ value: String, allowsLineBreaks: Bool = true) -> String {
        let newlines = CharacterSet.newlines
        // Normalize CRLF and lone CR to a single LF up front: a lone carriage return is itself a
        // line break (so it must survive in Details), while CRLF must not become two breaks.
        let value = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(value.unicodeScalars.count)

        for scalar in value.unicodeScalars {
            // Any Unicode line break (LF, NEL, U+2028 line / U+2029 paragraph separator, …) is
            // normalized to a single "\n" for multi-line content, or collapsed to a space for
            // single-line fields so no new line can be introduced into the report text.
            if newlines.contains(scalar) {
                scalars.append(allowsLineBreaks ? "\n" : " ")
                continue
            }

            if scalar == "\t" {
                scalars.append(allowsLineBreaks ? scalar : " ")
                continue
            }

            if !Self.isStrippable(scalar) {
                scalars.append(scalar)
            }
        }

        return String(scalars)
    }

    /// Every invisible / non-rendering scalar: controls, format characters, default-ignorable
    /// code points (ZWJ, ZWNJ, word joiner, variation selectors, tag characters, …), and bidi
    /// controls (ALM, LRM/RLM, embeddings, overrides, isolates). Newline and tab are handled by
    /// the caller before this is consulted. (UR-29)
    private static func isStrippable(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        let category = properties.generalCategory
        return category == .control
            || category == .format
            || properties.isDefaultIgnorableCodePoint
            || properties.isBidiControl
    }
}

public struct BugReportAppSnapshot: Equatable, Codable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

public struct BugReportDeviceSnapshot: Equatable, Codable, Sendable {
    public let iosVersion: String
    public let deviceFamily: String
    public let locale: String

    public init(iosVersion: String, deviceFamily: String, locale: String) {
        self.iosVersion = iosVersion
        self.deviceFamily = deviceFamily
        self.locale = locale
    }
}

public struct BugReportVPNSnapshot: Equatable, Codable, Sendable {
    public let status: String
    public let resolverPreset: String
    public let health: TunnelHealthSnapshot

    public init(status: String, resolverPreset: String, health: TunnelHealthSnapshot) {
        self.status = status
        self.resolverPreset = resolverPreset
        self.health = health
    }
}

public struct BugReportAffectedSiteFilterDecision: Equatable, Codable, Sendable {
    public let domain: String
    public let action: FilterAction
    public let reason: FilterDecisionReason

    public init(domain: String, action: FilterAction, reason: FilterDecisionReason) {
        self.domain = domain
        self.action = action
        self.reason = reason
    }

    public static func make(rawAffectedSite: String, snapshot: any FilterRuntimeSnapshot) -> Self? {
        guard let domain = normalizedDomain(from: rawAffectedSite) else {
            return nil
        }

        let decision = snapshot.decision(forNormalizedDomain: domain)
        return BugReportAffectedSiteFilterDecision(
            domain: domain,
            action: decision.action,
            reason: decision.reason
        )
    }

    private static func normalizedDomain(from rawAffectedSite: String) -> String? {
        let trimmed = rawAffectedSite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate: String
        if let host = URLComponents(string: trimmed)?.host, !host.isEmpty {
            candidate = host
        } else if let host = URLComponents(string: "https://\(trimmed)")?.host, !host.isEmpty {
            candidate = host
        } else {
            candidate = trimmed
        }

        return try? DomainName.normalize(candidate)
    }
}

public struct BugReportFilterSummary: Equatable, Codable, Sendable {
    public let catalogVersion: String?
    public let enabledListIDs: [String]
    public let snapshotVersion: String?
    public let compiledRuleCount: Int
    public let blocklistRuleCount: Int
    public let customBlocklistCount: Int
    public let enabledCustomBlocklistCount: Int
    public let affectedSiteDecision: BugReportAffectedSiteFilterDecision?

    public init(
        catalogVersion: String?,
        enabledListIDs: [String],
        snapshotVersion: String?,
        compiledRuleCount: Int,
        blocklistRuleCount: Int,
        customBlocklistCount: Int = 0,
        enabledCustomBlocklistCount: Int = 0,
        affectedSiteDecision: BugReportAffectedSiteFilterDecision? = nil
    ) {
        self.catalogVersion = catalogVersion
        self.enabledListIDs = enabledListIDs
        self.snapshotVersion = snapshotVersion
        self.compiledRuleCount = compiledRuleCount
        self.blocklistRuleCount = blocklistRuleCount
        self.customBlocklistCount = customBlocklistCount
        self.enabledCustomBlocklistCount = enabledCustomBlocklistCount
        self.affectedSiteDecision = affectedSiteDecision
    }
}

public struct BugReportPreviewItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct BugReportPreviewSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let purpose: String
    public let items: [BugReportPreviewItem]

    public init(id: String, title: String, purpose: String, items: [BugReportPreviewItem]) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.items = items
    }
}

public struct BugReportDebugLogEntry: Equatable, Codable, Sendable {
    public let component: String
    public let event: String
    public let timestamp: String
    public let details: [String: String]

    public init(component: String, event: String, timestamp: String, details: [String: String]) {
        self.component = Self.trim(component, maxLength: 40)
        self.event = Self.trim(event, maxLength: 80)
        self.timestamp = Self.trim(timestamp, maxLength: 40)
        self.details = details.reduce(into: [String: String]()) { output, pair in
            output[Self.trim(pair.key, maxLength: 80)] = Self.trim(pair.value, maxLength: 180)
        }
    }

    public static func parseJSONLines(_ data: Data, limit: Int = 40) -> [BugReportDebugLogEntry] {
        let text = String(decoding: data, as: UTF8.self)
        let entries = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> BugReportDebugLogEntry? in
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let component = object["component"] as? String,
                      let event = object["event"] as? String,
                      let timestamp = object["timestamp"] as? String
                else {
                    return nil
                }

                var details: [String: String] = [:]
                for (key, value) in object where allowedDetailKeys.contains(key) {
                    if let scalar = stringValue(value) {
                        details[key] = scalar
                    }
                }

                return BugReportDebugLogEntry(
                    component: component,
                    event: event,
                    timestamp: timestamp,
                    details: details
                )
            }

        guard entries.count > limit else {
            return entries
        }

        return Array(entries.suffix(limit))
    }

    public var dictionary: [String: Any] {
        [
            "component": component,
            "event": event,
            "timestamp": timestamp,
            "details": details
        ]
    }

    private static let allowedDetailKeys: Set<String> = [
        "allowRuleCount",
        "activeCount",
        "attemptsInWindow",
        "blockRuleCount",
        "canUseDeviceDNSFallback",
        "catalogVersion",
        "compiledRuleCount",
        "connectionStatus",
        "consecutiveUpstreamFailureCount",
        "consecutiveSmokeFailures",
        "consecutiveRejectedResponses",
        "count",
        // Self-reconnect suppression diagnostics (why a wedge did not restart the
        // tunnel): a decision label + the gating booleans. Privacy-safe — no
        // queried domain, just policy state.
        "decision",
        "onDemandConfirmed",
        "protectionEnabled",
        "deviceDNSFallbackActivationCount",
        "deviceDNSFallbackModeActive",
        "dnsServerAddress",
        "dnsSmokeProbeFailureCount",
        "dnsSmokeProbeSuccessCount",
        "durationMs",
        "errorKind",
        "errorCode",
        "errorDescription",
        "errorDomain",
        "evidenceCount",
        "failure",
        "fallbackModeActive",
        "fingerprint",
        "guardrailRuleCount",
        "isEnabled",
        "isSatisfied",
        "isVPNConfigurationInstalled",
        "kind",
        "lastDNSSmokeProbeAt",
        "lastDNSSmokeProbeSucceeded",
        "lastFailureReason",
        "lastNetworkChangeAt",
        "lastResolverRuntimeResetAt",
        "lastResolverTransport",
        "lastUpstreamFailureAt",
        "lastUpstreamSuccessAt",
        "manager",
        "networkKind",
        "networkPathIsSatisfied",
        "operationID",
        "operationKind",
        "parentSpanID",
        "pendingResponses",
        "primaryAction",
        "previousKind",
        "previousSatisfied",
        "providerBundleIdentifier",
        "reason",
        "resolver",
        "resolverIdentifier",
        "resolverRuntimeResetCount",
        "route",
        "sequence",
        "severity",
        "spanEvent",
        "spanID",
        "spanName",
        "status",
        "tunnelAddress",
        "transport",
        "upstreamFailureCount",
        "upstreamSuccessCount",
        "upstreamTimeoutCount",
        // Recovery verification source ("forwarding" vs "smoke-probe") — policy
        // state, no queried domain.
        "verifiedBy",
        "vpnMessage",
        "vpnMessageIsError",
        "vpnStatus",

        // Release-promoted resolver/DNS diagnostics (counts, resolver endpoints,
        // outcomes, timings, fingerprints). Audited to never carry a queried
        // domain — they surface the Wi-Fi/cellular DNS-recovery story in the
        // optional Feedback report now that the device debug log ships in Release.
        "bootstrapAllowRuleCount",
        "bootstrapBlockRuleCount",
        "bootstrapCount",
        "dohHTTPVersion",
        "endpoint",
        "error",
        "fallbackAccepted",
        "fallbackHasResponse",
        "fallbackOutcome",
        "footprintMB",
        "generation",
        "handshakeMs",
        "hostname",
        "ipv4Count",
        "ipv6Count",
        "negotiatedALPN",
        "outcome",
        "phase",
        "primaryAccepted",
        "primaryHasResponse",
        "primaryOutcome",
        "protocol",
        "resolverCount",
        "succeeded",
        "underlyingError",

        // Build provenance stamped on startTunnel-begin so every captured tunnel
        // session is attributable to an exact app version / build / source commit
        // (a single export can span an app update). Not PII — version/build/SHA only.
        "appVersion",
        "appBuild",
        "sourceRevision"
    ]

    private static func stringValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func trim(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }

        return String(value.prefix(maxLength))
    }
}

public struct BugReportBundle: Sendable {
    public let reportID: UUID
    public let context: BugReportContext
    public let app: BugReportAppSnapshot
    public let device: BugReportDeviceSnapshot
    public let vpn: BugReportVPNSnapshot
    public let filters: BugReportFilterSummary
    public let diagnostics: DiagnosticsStore
    public let localHistoryEnabled: Bool
    public let debugLogEntries: [BugReportDebugLogEntry]

    public init(
        reportID: UUID = UUID(),
        context: BugReportContext,
        app: BugReportAppSnapshot,
        device: BugReportDeviceSnapshot,
        vpn: BugReportVPNSnapshot,
        filters: BugReportFilterSummary,
        diagnostics: DiagnosticsStore,
        localHistoryEnabled: Bool,
        debugLogEntries: [BugReportDebugLogEntry]
    ) {
        self.reportID = reportID
        self.context = context
        self.app = app
        self.device = device
        self.vpn = vpn
        self.filters = filters
        self.diagnostics = diagnostics
        self.localHistoryEnabled = localHistoryEnabled
        self.debugLogEntries = debugLogEntries
    }

    public var previewSections: [BugReportPreviewSection] {
        [
            whatHappenedSection,
            appDeviceSection,
            vpnStatusSection,
            lifecycleLogSection,
            networkResolverSection,
            filterSnapshotSection,
            localActivitySection
        ]
    }

    public func makeRequestBody() -> [String: Any] {
        var body: [String: Any] = [
            "report_id": reportID.uuidString.lowercased(),
            "include_recent_dns_events": false,
            "include_optional_diagnostics": context.includeDiagnostics,
            "kind": context.issueType.kind.rawValue,
            "user_description": context.userDescription
        ]

        if context.includeDiagnostics {
            body["app"] = [
                "version": app.version,
                "build": app.build
            ]
            body["device"] = [
                "ios_version": device.iosVersion,
                "device_family": device.deviceFamily,
                "locale": device.locale
            ]
            body["vpn"] = vpnBody
            body["filters"] = filtersBody
            body["diagnostics"] = diagnosticsBody
            body["debug_log"] = debugLogEntries.map(\.dictionary)
        }

        if let contactEmail = context.normalizedContactEmail {
            body["contact_email"] = contactEmail
        }

        return body
    }

    private var vpnBody: [String: Any] {
        [
            "status": vpn.status,
            "resolver_preset": vpn.resolverPreset,
            "network_kind": vpn.health.networkKind.rawValue,
            "last_failure_reason": vpn.health.lastFailureReason ?? "none",
            "upstream_success_count": vpn.health.upstreamSuccessCount,
            "upstream_failure_count": vpn.health.upstreamFailureCount,
            "consecutive_upstream_failure_count": vpn.health.consecutiveUpstreamFailureCount,
            "upstream_timeout_count": vpn.health.upstreamTimeoutCount,
            "cache_hit_rate": vpn.health.cacheHitRate,
            "tcp_fallback_attempt_count": vpn.health.tcpFallbackAttemptCount,
            "tcp_fallback_success_count": vpn.health.tcpFallbackSuccessCount,
            "network_path_is_satisfied": vpn.health.networkPathIsSatisfied,
            "dns_smoke_probe_success_count": vpn.health.dnsSmokeProbeSuccessCount,
            "dns_smoke_probe_failure_count": vpn.health.dnsSmokeProbeFailureCount,
            "last_dns_smoke_probe_at": Self.dateString(vpn.health.lastDNSSmokeProbeAt) ?? "none",
            "last_dns_smoke_probe_succeeded": vpn.health.lastDNSSmokeProbeSucceeded.map { $0 as Any } ?? "unknown",
            "last_resolver_transport": vpn.health.lastResolverTransport.rawValue,
            "device_dns_fallback_mode_active": vpn.health.deviceDNSFallbackModeActive,
            "last_device_dns_fallback_activated_at": Self.dateString(vpn.health.lastDeviceDNSFallbackActivatedAt) ?? "none",
            "device_dns_fallback_activation_count": vpn.health.deviceDNSFallbackActivationCount,
            "device_dns_fallback_attempt_count": vpn.health.deviceDNSFallbackAttemptCount,
            "device_dns_fallback_success_count": vpn.health.deviceDNSFallbackSuccessCount,
            "device_dns_unavailable_count": vpn.health.deviceDNSUnavailableCount
        ]
    }

    private var filtersBody: [String: Any] {
        var body: [String: Any] = [
            "catalog_version": filters.catalogVersion ?? "unknown",
            "enabled_list_ids": filters.enabledListIDs.sorted(),
            "snapshot_version": filters.snapshotVersion ?? "unknown",
            "compiled_rule_count": filters.compiledRuleCount,
            "blocklist_rule_count": filters.blocklistRuleCount,
            "custom_blocklist_count": filters.customBlocklistCount,
            "enabled_custom_blocklist_count": filters.enabledCustomBlocklistCount
        ]

        if let decision = filters.affectedSiteDecision {
            body["affected_site_domain"] = decision.domain
            body["affected_site_filter_action"] = decision.action.rawValue
            body["affected_site_filter_reason"] = decision.reason.rawValue
        }

        return body
    }

    private var diagnosticsBody: [String: Any] {
        let summary = diagnostics.summary
        return [
            "allowed_count": summary.allowedCount,
            "blocked_count": summary.blockedCount,
            "total_count": summary.totalCount,
            "block_rate": summary.blockRate,
            "local_protection_uptime_seconds": Int(summary.localProtectionUptime.rounded()),
            "local_history_enabled": localHistoryEnabled,
            "has_domain_history": !diagnostics.recentEvents.isEmpty
        ]
    }

    private var whatHappenedSection: BugReportPreviewSection {
        BugReportPreviewSection(
            id: "context",
            title: "What happened",
            purpose: "Your description tells support what to focus on. This is the most useful part of the report.",
            items: [
                item("issue", "Issue", context.issueType.title),
                item(
                    "affected_site",
                    "Affected site/domain",
                    context.normalizedAffectedSite.isEmpty ? "Not provided" : context.normalizedAffectedSite
                ),
                item("details", "Details", context.normalizedDetails.isEmpty ? "Not provided" : context.normalizedDetails)
            ]
        )
    }

    private var appDeviceSection: BugReportPreviewSection {
        BugReportPreviewSection(
            id: "app_device",
            title: "App & Device",
            purpose: "This helps reproduce bugs tied to a specific app build, iOS version, or device family.",
            items: [
                item("app_version", "App version", app.version),
                item("build", "Build", app.build),
                item("ios", "iOS", device.iosVersion),
                item("device", "Device family", device.deviceFamily),
                item("locale", "Locale", device.locale)
            ]
        )
    }

    private var vpnStatusSection: BugReportPreviewSection {
        BugReportPreviewSection(
            id: "vpn_status",
            title: "VPN Status",
            purpose: "This shows whether iOS thinks local protection is installed, starting, connected, or stopped.",
            items: [
                item("status", "Status", vpn.status),
                item("resolver", "Resolver", vpn.resolverPreset),
                item("network", "Network", vpn.health.networkKind.rawValue),
                item("last_failure", "Last failure", vpn.health.lastFailureReason ?? "None")
            ]
        )
    }

    private var lifecycleLogSection: BugReportPreviewSection {
        let latest = debugLogEntries.last
        return BugReportPreviewSection(
            id: "lifecycle_log",
            title: "Tunnel Lifecycle Log",
            purpose: "This includes recent app, VPN, and tunnel handling events. It does not include DNS requests.",
            items: [
                item("entry_count", "Entries", "\(debugLogEntries.count)"),
                item("latest_event", "Latest event", latest.map { "\($0.component): \($0.event)" } ?? "No recent lifecycle events"),
                item("scope", "Scope", "Lifecycle events only")
            ]
        )
    }

    private var networkResolverSection: BugReportPreviewSection {
        BugReportPreviewSection(
            id: "network_resolver",
            title: "Network & Resolver Health",
            purpose: "These counters help diagnose slow internet, DNS timeouts, resolver failures, and Wi-Fi or cellular handoff issues.",
            items: [
                item("upstream_success", "Upstream successes", "\(vpn.health.upstreamSuccessCount)"),
                item("upstream_failure", "Upstream failures", "\(vpn.health.upstreamFailureCount)"),
                item("consecutive_upstream_failure", "Consecutive upstream failures", "\(vpn.health.consecutiveUpstreamFailureCount)"),
                item("timeouts", "Timeouts", "\(vpn.health.upstreamTimeoutCount)"),
                item("cache_hit_rate", "Cache hit rate", percent(vpn.health.cacheHitRate)),
                item("tcp_fallback", "TCP fallback", "\(vpn.health.tcpFallbackSuccessCount)/\(vpn.health.tcpFallbackAttemptCount)"),
                item("dns_smoke_probe", "DNS smoke probes", "\(vpn.health.dnsSmokeProbeSuccessCount)/\(vpn.health.dnsSmokeProbeSuccessCount + vpn.health.dnsSmokeProbeFailureCount)"),
                item("last_resolver_transport", "Last resolver transport", vpn.health.lastResolverTransport.rawValue),
                item("device_dns_fallback_active", "Device DNS fallback active", vpn.health.deviceDNSFallbackModeActive ? "Yes" : "No"),
                item("device_dns_fallback", "Device DNS fallback", "\(vpn.health.deviceDNSFallbackActivationCount) activations"),
                item("device_dns_unavailable", "Device DNS unavailable", "\(vpn.health.deviceDNSUnavailableCount)"),
                item("network_changes", "Network changes", "\(vpn.health.networkChangeCount)")
            ]
        )
    }

    private var filterSnapshotSection: BugReportPreviewSection {
        var items = [
            item("catalog", "Catalog", filters.catalogVersion ?? "Unknown"),
            item("enabled_lists", "Enabled lists", "\(filters.enabledListIDs.count)"),
            item("snapshot", "Snapshot", filters.snapshotVersion ?? "Unknown"),
            item("rules", "Compiled rules", "\(filters.compiledRuleCount)"),
            item("blocklist_rules", "Blocklist rules", "\(filters.blocklistRuleCount)"),
            item("custom_blocklists", "Custom blocklists", "\(filters.enabledCustomBlocklistCount)/\(filters.customBlocklistCount)")
        ]

        if let decision = filters.affectedSiteDecision {
            items.append(
                item(
                    "affected_site_filter",
                    "Affected site decision",
                    "\(decision.action.rawValue) (\(decision.reason.rawValue))"
                )
            )
        }

        return BugReportPreviewSection(
            id: "filter_snapshot",
            title: "Filter Snapshot",
            purpose: "This helps debug missing, stale, or incorrectly compiled filter lists.",
            items: items
        )
    }

    private var localActivitySection: BugReportPreviewSection {
        let summary = diagnostics.summary
        return BugReportPreviewSection(
            id: "local_activity",
            title: "Local Activity Summary",
            purpose: "Only counts are included, so support can tell whether protection is seeing traffic without receiving browsing history.",
            items: [
                item("blocked", "Blocked", "\(summary.blockedCount)"),
                item("allowed", "Allowed", "\(summary.allowedCount)"),
                item("block_rate", "Block rate", percent(summary.blockRate)),
                item("uptime", "Protected time", "\(Int(summary.localProtectionUptime.rounded())) seconds"),
                item("domain_log", "Recent domain log", "Not included")
            ]
        )
    }

    private func item(_ id: String, _ label: String, _ value: String) -> BugReportPreviewItem {
        BugReportPreviewItem(id: id, label: label, value: value)
    }

    private func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    private static func dateString(_ date: Date?) -> String? {
        guard let date else {
            return nil
        }

        return SharedDateFormatting.iso8601.string(from: date)
    }
}

public enum BugReportSubmissionBundlePolicy {
    public static func bundleToSubmit(
        draft: BugReportBundle?,
        currentContext: BugReportContext,
        makeFreshBundle: () -> BugReportBundle
    ) -> BugReportBundle {
        if let draft, draft.context == currentContext {
            return draft
        }

        return makeFreshBundle()
    }
}
