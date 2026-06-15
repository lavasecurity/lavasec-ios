import Foundation

public enum BugReportIssueType: String, CaseIterable, Codable, Identifiable, Sendable {
    case websiteAccess
    case vpnOrFilterIssue
    case featureIssue
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
        case .other:
            "Something else"
        }
    }
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
        Self.trim(affectedSite, maxLength: 300)
    }

    public var normalizedDetails: String {
        Self.trim(details, maxLength: 5_000)
    }

    public var normalizedContactEmail: String? {
        guard let contactEmail else {
            return nil
        }

        let trimmed = Self.trim(contactEmail, maxLength: 320)
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

    private static func trim(_ value: String, maxLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else {
            return trimmed
        }

        return String(trimmed.prefix(maxLength))
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
        "blockRuleCount",
        "canUseDeviceDNSFallback",
        "catalogVersion",
        "compiledRuleCount",
        "connectionStatus",
        "consecutiveUpstreamFailureCount",
        "count",
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
        "failure",
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
        "vpnMessage",
        "vpnMessageIsError",
        "vpnStatus"
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
