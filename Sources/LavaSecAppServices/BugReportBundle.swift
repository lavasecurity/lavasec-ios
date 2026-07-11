import Foundation
import LavaSecFilterPipeline
import LavaSecKit

/// Coarse classification used by triage to separate defects from product ideas.
/// Sent to the backend alongside the report so the promoter can label the Linear
/// issue (`[bug]` / `[suggestion]` / `[other]`) and the triage agent can route it.
package enum BugReportIssueKind: String, Codable, Sendable {
    case bug
    case suggestion
    case other
}

/// User-selectable feedback topic used to label and describe a report.
public enum BugReportIssueType: String, CaseIterable, Codable, Identifiable, Sendable {
    // Bug topics first, then the suggestion topic, then a true catch-all "other".
    // Order here is the order shown in the feedback topic picker (allCases).
    /// A website or domain cannot be reached.
    case websiteAccess
    /// VPN connectivity or filtering behaves incorrectly.
    case vpnOrFilterIssue
    /// An app feature behaves incorrectly.
    case featureIssue
    /// User-facing translation needs correction.
    case translationIssue
    /// Product suggestion rather than a defect report.
    case suggestion
    /// Feedback that does not match a more specific topic.
    case other

    /// Stable identifier derived from the persisted raw value.
    public var id: String {
        rawValue
    }

    /// User-facing picker title for the topic.
    public var title: String {
        switch self {
        case .websiteAccess:
            "I can't visit a website"
        case .vpnOrFilterIssue:
            "VPN or filter doesn't work"
        case .featureIssue:
            "A Lava feature doesn't work"
        case .translationIssue:
            "Translation is not quite right"
        case .suggestion:
            "I have a suggestion"
        case .other:
            "Something else"
        }
    }

    package var kind: BugReportIssueKind {
        switch self {
        case .websiteAccess, .vpnOrFilterIssue, .featureIssue, .translationIssue:
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
    /// Maximum character count for the affected-site field.
    public static let affectedSite = 300
    /// Maximum character count for the details field.
    public static let details = 5_000
    /// Maximum character count for the contact-email field.
    public static let contactEmail = 320
}

/// Raw feedback fields plus the user's optional-diagnostics choice.
public struct BugReportContext: Equatable, Codable, Sendable {
    /// Selected feedback topic.
    public private(set) var issueType: BugReportIssueType
    /// Raw affected-site input supplied by the user.
    public private(set) var affectedSite: String
    /// Raw free-form details supplied by the user.
    public private(set) var details: String
    /// Raw optional contact email supplied by the user.
    public private(set) var contactEmail: String?
    /// Whether optional device and protection diagnostics should be attached.
    public private(set) var includeDiagnostics: Bool

    /// Creates a context by storing raw inputs; normalized projections are computed on read.
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

    /// Sanitized, single-line, length-limited affected-site value.
    public var normalizedAffectedSite: String {
        // Single-line field: collapse any embedded line breaks so a pasted value can't inject a
        // fake "Details:"/"Issue:" line into the composed userDescription (UR-29).
        Self.trim(affectedSite, maxLength: BugReportInputLimits.affectedSite, allowsLineBreaks: false)
    }

    /// Sanitized, length-limited details value with normalized line breaks.
    public var normalizedDetails: String {
        Self.trim(details, maxLength: BugReportInputLimits.details, allowsLineBreaks: true)
    }

    /// Sanitized single-line email, returning `nil` when absent or empty after normalization.
    public var normalizedContactEmail: String? {
        guard let contactEmail else {
            return nil
        }

        // Single-line field: no embedded line breaks.
        let trimmed = Self.trim(contactEmail, maxLength: BugReportInputLimits.contactEmail, allowsLineBreaks: false)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Structured issue, affected-site, and details text with empty optional lines omitted.
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

/// App version information attached to optional bug-report diagnostics.
public struct BugReportAppSnapshot: Equatable, Codable, Sendable {
    /// Marketing version string.
    public let version: String
    /// Build identifier string.
    public let build: String

    /// Creates an app snapshot from version and build strings.
    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

/// Device environment information attached to optional bug-report diagnostics.
public struct BugReportDeviceSnapshot: Equatable, Codable, Sendable {
    /// Operating-system version string.
    public let iosVersion: String
    /// Device-family description.
    public let deviceFamily: String
    /// Locale identifier active when the snapshot was made.
    public let locale: String

    /// Creates a device snapshot from the supplied environment strings.
    public init(iosVersion: String, deviceFamily: String, locale: String) {
        self.iosVersion = iosVersion
        self.deviceFamily = deviceFamily
        self.locale = locale
    }
}

/// Protection status, selected resolver, and tunnel health captured for a report.
public struct BugReportVPNSnapshot: Equatable, Codable, Sendable {
    /// Display status of the VPN connection.
    public let status: String
    /// Display identifier or name for the selected resolver preset.
    public let resolverPreset: String
    /// Detailed tunnel-health counters and timestamps.
    public let health: TunnelHealthSnapshot

    /// Creates a VPN snapshot from status, resolver, and health values.
    public init(status: String, resolverPreset: String, health: TunnelHealthSnapshot) {
        self.status = status
        self.resolverPreset = resolverPreset
        self.health = health
    }
}

/// Filter decision evaluated specifically for the user's affected-site input.
public struct BugReportAffectedSiteFilterDecision: Equatable, Codable, Sendable {
    /// Domain associated with the filter decision.
    public let domain: String
    /// Filter action selected for the domain.
    public let action: FilterAction
    /// Rule source or fallback reason behind the action.
    public let reason: FilterDecisionReason

    /// Creates a decision record from the supplied domain, action, and reason.
    public init(domain: String, action: FilterAction, reason: FilterDecisionReason) {
        self.domain = domain
        self.action = action
        self.reason = reason
    }

    /// Normalizes a URL or domain and evaluates it, returning `nil` for invalid or empty input.
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

/// Filter configuration and compiled-snapshot counts attached to a report.
public struct BugReportFilterSummary: Equatable, Codable, Sendable {
    /// Catalog version used for the snapshot, when known.
    public let catalogVersion: String?
    /// Enabled curated-list identifiers.
    public let enabledListIDs: [String]
    /// Compiled filter-snapshot version, when known.
    public let snapshotVersion: String?
    /// Total compiled rule count.
    public let compiledRuleCount: Int
    /// Compiled blocklist-rule count.
    public let blocklistRuleCount: Int
    /// Number of configured custom blocklists.
    public let customBlocklistCount: Int
    /// Number of enabled custom blocklists.
    public let enabledCustomBlocklistCount: Int
    /// Decision associated with the user-supplied affected site, when present.
    public let affectedSiteDecision: BugReportAffectedSiteFilterDecision?

    /// Creates a summary by storing the supplied catalog, snapshot, and rule-count values.
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

/// One labeled value shown in the pre-submission diagnostics preview.
public struct BugReportPreviewItem: Identifiable, Equatable, Sendable {
    /// Stable identifier within its preview section.
    public let id: String
    /// User-facing label describing the value.
    public let label: String
    /// User-facing rendered value.
    public let value: String

    /// Creates a preview item from an identifier, label, and rendered value.
    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Group of related values disclosed in the pre-submission diagnostics preview.
public struct BugReportPreviewSection: Identifiable, Equatable, Sendable {
    /// Stable section identifier.
    public let id: String
    /// User-facing section title.
    public let title: String
    /// Explanation of why the section is included.
    public let purpose: String
    /// Labeled values disclosed by the section.
    public let items: [BugReportPreviewItem]

    /// Creates a preview section from its identity, explanatory copy, and items.
    public init(id: String, title: String, purpose: String, items: [BugReportPreviewItem]) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.items = items
    }
}

/// Serializable projection of one device debug-log line.
public struct BugReportDebugLogEntry: Equatable, Codable, Sendable {
    /// Subsystem or process label stored for the entry.
    public let component: String
    /// Event label stored for the entry.
    public let event: String
    /// Timestamp string carried by the source log.
    public let timestamp: String
    /// Detail values stored for the entry.
    public let details: [String: String]

    /// Creates an entry while truncating labels, detail keys, and detail values to report limits.
    public init(component: String, event: String, timestamp: String, details: [String: String]) {
        self.component = Self.trim(component, maxLength: 40)
        self.event = Self.trim(event, maxLength: 80)
        self.timestamp = Self.trim(timestamp, maxLength: 40)
        self.details = details.reduce(into: [String: String]()) { output, pair in
            output[Self.trim(pair.key, maxLength: 80)] = Self.trim(pair.value, maxLength: 180)
        }
    }

    /// Parses a log split across file generations (rotated first, current last): joins the
    /// chunks in order with a newline guard at each boundary — a rotation can land mid-write,
    /// and without the guard the last rotated line and the first current line would fuse into
    /// one unparseable line. Ordering matters: the entry cap keeps the newest entries via
    /// `suffix`, so older generations must come first.
    public static func parseJSONLines(
        concatenating chunks: [Data],
        limit: Int = 40
    ) -> [BugReportDebugLogEntry] {
        var combined = Data()
        for chunk in chunks where !chunk.isEmpty {
            if let last = combined.last, last != UInt8(ascii: "\n") {
                combined.append(UInt8(ascii: "\n"))
            }
            combined.append(chunk)
        }
        return parseJSONLines(combined, limit: limit)
    }

    /// Parses valid JSON lines, allowlists scalar details, drops report-window churn, and keeps the newest entries.
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
            // Drop presentation-churn BEFORE the suffix so the small report window keeps the
            // tunnel / DNS / self-reconnect events that explain the incident (LAV-94 A).
            .filter { !$0.isReportWindowChurn }

        guard entries.count > limit else {
            return entries
        }

        return Array(entries.suffix(limit))
    }

    /// High-frequency events that carry no incident-diagnostic value but, left in, flood the
    /// last-`limit` report window and evict the tunnel / DNS / self-reconnect events that actually
    /// explain a "reconnecting on its own" report. The full on-device debug log still retains them;
    /// only the bug-report projection drops them.
    var isReportWindowChurn: Bool {
        // Live-activity reconcile: presentation-only, fires every few seconds (≈14 in 40s in
        // report 186bdad3) — it only reflects Live Activity state (LAV-94 A).
        if component == "live-activity-controller", event == "reconcile" {
            return true
        }
        // Per-query resolver wire-attempt latency spans fire ~2 begin/end entries PER DNS query
        // (emitted ONLY in DEBUG/LAVA_QA_TOOLS builds). On a busy or recovering link they dominate
        // the window (~30 of 40 in the on-device QA replay on 2026-06-22) and evict the
        // self-reconnect/teardown events. The per-query churn carries no operation identity in the
        // report projection (no spanName, or the resolver.endpointAttempt span), whereas
        // operation-lifecycle spans (e.g. "tunnel.setNetworkSettings") carry a meaningful spanName
        // and ARE kept. Per-query latency still lives in the vpn health counters and the full
        // on-device log, so dropping the churn here only affects QA/internal reports — Release never
        // compiles these spans.
        if event == "latency-span-begin" || event == "latency-span-end" {
            let spanName = details["spanName"]
            return spanName == nil || spanName == "resolver.endpointAttempt"
        }
        return false
    }

    /// JSON-compatible dictionary representation used in the request body.
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
        "compactReason",
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
        // Age of the corroborating evidence at a routine dns-smoke-probe skip (#196): lets a
        // field report confirm the skip fired inside the ≤300 s honesty-budget window rather
        // than on stale evidence. A millisecond count, never a domain (COH-3, Codex mirror
        // of the worker detail allowlist).
        "evidenceAgeMs",
        "evidenceCount",
        "failure",
        "fallbackModeActive",
        "fingerprint",
        // Duration of a closed self-reconnect gap (self-reconnect-gap-closed) — a
        // millisecond count, never a domain.
        "gapMs",
        // Whether that gap's end was FLOORED because the wall clock stepped backward past the
        // recorded start (COH-2) — a Bool, never a domain. Without this in the allowlist the
        // exported report drops the flag and shows only the synthetic gapMs=1000, so support
        // can't tell the duration was floored rather than measured (Codex #219).
        "clockAnomaly",
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
        "maxRuleCount",
        "networkKind",
        "networkPathIsSatisfied",
        "operationID",
        "operationKind",
        "parentSpanID",
        "pendingResponses",
        "preparedReason",
        "primaryAction",
        "previousKind",
        "previousSatisfied",
        "providerBundleIdentifier",
        "reason",
        "resolver",
        "resolverIdentifier",
        "resolverRuntimeResetCount",
        "route",
        "ruleCount",
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
        // Coalesced encrypted-fallback count: how many throttled "dns-encrypted-fallback"
        // events the emitted marker stands in for. A bare integer, no queried domain —
        // preserves the "how often" the log-coalescing keeps, so it survives into exports.
        "carriedSinceLastLog",
        "dohHTTPVersion",
        "endpoint",
        "error",
        "fallbackAccepted",
        "fallbackHasResponse",
        "fallbackOutcome",
        "footprintMB",
        "generation",
        "eligibleStoreCount",
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
        "storeCount",
        "succeeded",
        "syncCap",
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

/// A privacy-safe, REDACTED snapshot of the recovery / escalation state at report time — the
/// "why did it (or didn't it) self-reconnect" evidence. Derived entirely from the tunnel health
/// counters (already in the report) plus the tunnel's persisted self-reconnect attempt timeline,
/// which survives the restart. Carries NO resolved domains / browsing history — only timestamps,
/// counts, and policy reason labels — so it stays on the right side of the data-minimization line.
/// It exists so a "reconnecting on its own" / "protected but no internet" report carries the
/// INCIDENT instead of only the symptom: the cluster's reports had `has_recent_dns_events = false`
/// and a debug-log window flooded by live-activity reconciles (LAV-94 B).
/// Durable self-reconnect gap evidence (LAV-92/93), read app-side from the shared app group.
/// The gap starts at the teardown commit and ends at the next tunnel launch (the process is
/// serving again); `endedAt` is nil while a gap is still open (Connect-On-Demand has not
/// relaunched the tunnel yet). `cumulativeCount` counts committed teardowns for the install's
/// lifetime — frequency evidence the rate-limiter's crediting deliberately erases.
public struct SelfReconnectGapRecord: Equatable, Sendable {
    /// Wall-clock time at which the tunnel teardown gap began.
    public let startedAt: Date
    /// Wall-clock time at which a replacement tunnel launched, or `nil` while open.
    public let endedAt: Date?
    /// Install-lifetime count of committed self-reconnect teardowns.
    public let cumulativeCount: Int

    /// Creates a gap record from its start, optional end, and cumulative count.
    public init(startedAt: Date, endedAt: Date?, cumulativeCount: Int) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cumulativeCount = cumulativeCount
    }

    /// Duration of the recorded gap, defined only once it closed.
    public var gapMilliseconds: Int? {
        endedAt.map { max(0, Int(($0.timeIntervalSince(startedAt) * 1_000).rounded())) }
    }
}

package struct BugReportIncidentSummary: Equatable, Sendable {
    /// Bound on the surfaced timeline so a long-running session can't bloat the payload.
    package static let maxSelfReconnectTimes = 20

    package let selfReconnectTimes: [Date]
    package let lastFailureReason: String?
    package let consecutiveUpstreamFailureCount: Int
    package let consecutiveDNSSmokeProbeFailureCount: Int
    package let consecutiveRejectedSmokeResponseCount: Int
    package let lastUpstreamFailureAt: Date?
    package let lastUpstreamSuccessAt: Date?
    package let lastPrimaryUpstreamSuccessAt: Date?
    package let lastEncryptedFallbackSuccessAt: Date?
    package let lastDNSSmokeProbeAt: Date?
    package let lastDNSSmokeProbeSucceeded: Bool?
    package let lastNetworkChangeAt: Date?
    package let networkChangeCount: Int
    package let lastResolverRuntimeResetAt: Date?
    package let lastResolverRuntimeResetReason: String?
    package let resolverRuntimeResetCount: Int
    package let lastResolverIdentityChangeAt: Date?
    /// Fail-closed serve trace (session-scoped, from TunnelHealthSnapshot). Kept out of
    /// user-facing counts (#164); surfaced here so a fail-closed window is distinguishable
    /// from "no incident" in a field report.
    package let failClosedServedQueryCount: Int
    package let lastFailClosedAt: Date?
    package let lastFailClosedReason: String?
    /// The most recent Focus-driven switch attempt (LAV-100 Phase 4). Diagnostic-only, privacy-safe; lets a
    /// closed-app Focus failure be localized on internal TestFlight without a device or the QA device log.
    package let lastFocusSwitch: FocusSwitchDiagnosticRecord?
    /// Durable gap evidence (LAV-92/93) — survives the productive credit and the 600 s prune.
    package let selfReconnectGap: SelfReconnectGapRecord?
    /// Whether the recorded gap is ONGOING (still open — protection has been down the whole
    /// time, however long) or ENDED within the last 24 h (a 3-day outage that ended an hour
    /// ago is fresh evidence). `hasContent` keys on this, not on the record's existence: the
    /// record never expires (that is its job), and a long-closed install-lifetime record
    /// flipping `has_incident_summary` true forever would be the same misleading-true failure
    /// the always-persisted Focus record has.
    package let hasRecentSelfReconnectGap: Bool
    /// OBS R2: the append-only incident ledger timeline (oldest-first, already bounded
    /// to 50 records / 7 days by the store). Decoupled from the policy stores, so a
    /// report filed 30 minutes after a thrash finally carries the timestamped incident.
    package let recentIncidents: [IncidentLedgerRecord]
    /// Like the gap: `hasContent` keys on RECENCY (any ledger record < 24 h old), not
    /// on the file's existence — week-old records are context, not a live incident.
    package let hasRecentLedgerIncident: Bool
    /// The Focus record never expires (that is its job as a diagnostic of the LAST
    /// switch), so its bare existence must not flip `has_incident_summary` forever —
    /// the misleading-true failure the 2026-07 review flagged (OBS-1). Recency-gated
    /// like the gap and the ledger.
    package let hasRecentFocusSwitch: Bool

    package init(
        health: TunnelHealthSnapshot,
        selfReconnectTimes: [Date],
        lastFocusSwitch: FocusSwitchDiagnosticRecord? = nil,
        selfReconnectGap: SelfReconnectGapRecord? = nil,
        recentIncidents: [IncidentLedgerRecord] = [],
        now: Date = Date()
    ) {
        // Prune to the tunnel's active attempt window FIRST. The persisted defaults array is
        // only normalized by the tunnel when it evaluates a wedge (TunnelSelfReconnectPolicy),
        // so a report filed after a quiet stretch would otherwise carry self-reconnect timestamps
        // that are long past the window and falsely flag `has_incident_summary`/`hasContent` with a
        // stale timeline. Reuse the same prune (clamps future-dated, drops out-of-window) so the
        // report can never disagree with the tunnel about what counts as a recent attempt.
        // Then sort + cap so the timeline is deterministic and bounded regardless of caller order.
        let recentSelfReconnectTimes = TunnelSelfReconnectPolicy.prunedAttemptTimes(selfReconnectTimes, now: now)
        self.selfReconnectTimes = Array(recentSelfReconnectTimes.sorted().suffix(Self.maxSelfReconnectTimes))
        self.lastFailureReason = health.lastFailureReason
        self.consecutiveUpstreamFailureCount = health.consecutiveUpstreamFailureCount
        self.consecutiveDNSSmokeProbeFailureCount = health.consecutiveDNSSmokeProbeFailureCount
        self.consecutiveRejectedSmokeResponseCount = health.consecutiveRejectedSmokeResponseCount
        self.lastUpstreamFailureAt = health.lastUpstreamFailureAt
        self.lastUpstreamSuccessAt = health.lastUpstreamSuccessAt
        self.lastPrimaryUpstreamSuccessAt = health.lastPrimaryUpstreamSuccessAt
        self.lastEncryptedFallbackSuccessAt = health.lastEncryptedFallbackSuccessAt
        self.lastDNSSmokeProbeAt = health.lastDNSSmokeProbeAt
        self.lastDNSSmokeProbeSucceeded = health.lastDNSSmokeProbeSucceeded
        self.lastNetworkChangeAt = health.lastNetworkChangeAt
        self.networkChangeCount = health.networkChangeCount
        self.lastResolverRuntimeResetAt = health.lastResolverRuntimeResetAt
        self.lastResolverRuntimeResetReason = health.lastResolverRuntimeResetReason
        self.resolverRuntimeResetCount = health.resolverRuntimeResetCount
        self.lastResolverIdentityChangeAt = health.lastResolverIdentityChangeAt
        self.failClosedServedQueryCount = health.failClosedServedQueryCount
        self.lastFailClosedAt = health.lastFailClosedAt
        self.lastFailClosedReason = health.lastFailClosedReason
        self.lastFocusSwitch = lastFocusSwitch
        self.selfReconnectGap = selfReconnectGap
        self.hasRecentSelfReconnectGap = selfReconnectGap.map { gap in
            // Recency keys on the gap's END: an open gap references `now` (ongoing evidence,
            // however old its start), a closed one stays recent for 24 h after it ended.
            now.timeIntervalSince(gap.endedAt ?? now) <= 24 * 60 * 60
        } ?? false
        self.recentIncidents = Array(recentIncidents.suffix(IncidentLedger.maximumRecordCount))
        // Compute the recency flag over the STORED (truncated) set so it provably matches the
        // incidents actually carried in the report — never a dropped-prefix record. In practice
        // the ledger is chronological and pre-capped at `maximumRecordCount`, so this is a no-op,
        // but it removes the unfiltered-vs-suffix asymmetry the reviewer flagged.
        self.hasRecentLedgerIncident = self.recentIncidents.contains { record in
            now.timeIntervalSince(record.at) <= 24 * 60 * 60
        }
        self.hasRecentFocusSwitch = lastFocusSwitch.map { record in
            now.timeIntervalSince(record.at) <= 24 * 60 * 60
        } ?? false
    }

    package var selfReconnectCount: Int {
        selfReconnectTimes.count
    }

    package var lastSelfReconnectAt: Date? {
        selfReconnectTimes.last
    }

    /// True when there is any recovery evidence worth reading — drives the honest
    /// `has_incident_summary` flag that replaces the always-false `has_recent_dns_events`.
    package var hasContent: Bool {
        !selfReconnectTimes.isEmpty
            || lastFailureReason != nil
            || consecutiveUpstreamFailureCount > 0
            || consecutiveDNSSmokeProbeFailureCount > 0
            || consecutiveRejectedSmokeResponseCount > 0
            || lastEncryptedFallbackSuccessAt != nil
            || resolverRuntimeResetCount > 0
            // A fail-closed window can be the ONLY evidence in a report (queries suppressed,
            // no self-reconnect fired because escalation is deliberately suppressed while the
            // snapshot is unavailable) — count it so the flag stays honest for that class.
            || failClosedServedQueryCount > 0
            // A RECENT gap (started < 24 h ago) is real incident evidence even after the
            // credit/prune erased the attempt timeline; the never-expiring record itself
            // deliberately does not flip the flag (see hasRecentSelfReconnectGap).
            || hasRecentSelfReconnectGap
            // A closed-app Focus switch can be the ONLY evidence in a report (e.g. it failed/deferred with no
            // DNS failures or self-reconnects). Count it so `has_incident_summary` is honest and backend triage
            // keyed off that flag doesn't skip the very diagnostic this surfaces (Codex round 7) — but only
            // while RECENT: the record never expires, and an install-lifetime record flipping the flag
            // forever is the misleading-true failure the 2026-07 review flagged (OBS-1).
            || hasRecentFocusSwitch
            // The ledger timeline follows the same recency rule (< 24 h). Older records still
            // SHIP (context for triage) — they just don't claim a live incident.
            || hasRecentLedgerIncident
    }

    package var dictionary: [String: Any] {
        var body: [String: Any] = [
            "self_reconnect_count": selfReconnectCount,
            "consecutive_upstream_failure_count": consecutiveUpstreamFailureCount,
            "consecutive_dns_smoke_probe_failure_count": consecutiveDNSSmokeProbeFailureCount,
            "consecutive_rejected_smoke_response_count": consecutiveRejectedSmokeResponseCount,
            "network_change_count": networkChangeCount,
            "resolver_runtime_reset_count": resolverRuntimeResetCount,
            "fail_closed_served_query_count": failClosedServedQueryCount
        ]

        if !selfReconnectTimes.isEmpty {
            body["self_reconnect_times"] = selfReconnectTimes.compactMap(Self.dateString)
        }
        Self.set(&body, "last_self_reconnect_at", lastSelfReconnectAt)
        if let lastFailureReason {
            body["last_failure_reason"] = lastFailureReason
        }
        Self.set(&body, "last_upstream_failure_at", lastUpstreamFailureAt)
        Self.set(&body, "last_upstream_success_at", lastUpstreamSuccessAt)
        Self.set(&body, "last_primary_upstream_success_at", lastPrimaryUpstreamSuccessAt)
        Self.set(&body, "last_encrypted_fallback_success_at", lastEncryptedFallbackSuccessAt)
        Self.set(&body, "last_dns_smoke_probe_at", lastDNSSmokeProbeAt)
        if let lastDNSSmokeProbeSucceeded {
            body["last_dns_smoke_probe_succeeded"] = lastDNSSmokeProbeSucceeded
        }
        Self.set(&body, "last_network_change_at", lastNetworkChangeAt)
        Self.set(&body, "last_resolver_runtime_reset_at", lastResolverRuntimeResetAt)
        if let lastResolverRuntimeResetReason {
            body["last_resolver_runtime_reset_reason"] = lastResolverRuntimeResetReason
        }
        Self.set(&body, "last_resolver_identity_change_at", lastResolverIdentityChangeAt)
        Self.set(&body, "last_fail_closed_at", lastFailClosedAt)
        if let lastFailClosedReason {
            body["last_fail_closed_reason"] = lastFailClosedReason
        }

        if let selfReconnectGap {
            body["self_reconnect_gap_count"] = selfReconnectGap.cumulativeCount
            Self.set(&body, "last_self_reconnect_gap_started_at", selfReconnectGap.startedAt)
            Self.set(&body, "last_self_reconnect_gap_ended_at", selfReconnectGap.endedAt)
            if let gapMilliseconds = selfReconnectGap.gapMilliseconds {
                body["last_self_reconnect_gap_ms"] = gapMilliseconds
            }
        }

        if !recentIncidents.isEmpty {
            body["recent_incidents"] = recentIncidents.map { record in
                var entry: [String: Any] = [
                    "at": SharedDateFormatting.iso8601.string(from: record.at),
                    "kind": record.kind.rawValue
                ]
                if let reason = record.reason {
                    entry["reason"] = reason
                }
                if let durationMs = record.durationMs {
                    entry["duration_ms"] = durationMs
                }
                if let verifiedBy = record.verifiedBy {
                    entry["verified_by"] = verifiedBy
                }
                return entry
            }
        }

        if let lastFocusSwitch {
            var focus: [String: Any] = [
                "outcome": lastFocusSwitch.outcome,
                "target_filter_id": lastFocusSwitch.targetFilterID,
                "at": SharedDateFormatting.iso8601.string(from: lastFocusSwitch.at)
            ]
            // The specific branch reason (e.g. "deferred-no-warm-artifact", "committed") — the key signal for
            // diagnosing a closed-app switch on Release. Omit when empty (a record from an older build).
            if !lastFocusSwitch.reason.isEmpty {
                focus["reason"] = lastFocusSwitch.reason
            }
            body["focus_last_switch"] = focus
        }

        return body
    }

    private static func set(_ body: inout [String: Any], _ key: String, _ date: Date?) {
        if let value = dateString(date) {
            body[key] = value
        }
    }

    private static func dateString(_ date: Date?) -> String? {
        guard let date else {
            return nil
        }

        return SharedDateFormatting.iso8601.string(from: date)
    }
}

/// Complete feedback payload and optional diagnostic snapshots prepared for review or submission.
public struct BugReportBundle: Sendable {
    /// Unique report identifier sent to backend triage.
    public let reportID: UUID
    /// User-entered feedback context and diagnostics choice.
    public let context: BugReportContext
    /// App version snapshot.
    public let app: BugReportAppSnapshot
    /// Device environment snapshot.
    public let device: BugReportDeviceSnapshot
    /// VPN status and tunnel-health snapshot.
    public let vpn: BugReportVPNSnapshot
    /// Filter configuration and compiled-rule summary.
    public let filters: BugReportFilterSummary
    /// Aggregate local filtering diagnostics.
    public let diagnostics: DiagnosticsStore
    /// Whether local domain history was enabled when the bundle was prepared.
    public let localHistoryEnabled: Bool
    /// Device debug-log entries selected for the report window.
    public let debugLogEntries: [BugReportDebugLogEntry]
    /// Recent self-reconnect attempt timestamps the tunnel persisted to the shared app group
    /// (read app-side — never touches the tunnel's frozen recovery path). Folded into `incident`.
    public let selfReconnectTimes: [Date]
    /// The last Focus-driven switch attempt (LAV-100 Phase 4), read app-side from the shared app group.
    /// Diagnostic-only; folded into `incident`.
    public let lastFocusSwitch: FocusSwitchDiagnosticRecord?
    /// Durable self-reconnect gap evidence (LAV-92/93), read app-side from the shared app group.
    /// Diagnostic-only; folded into `incident`.
    public let selfReconnectGap: SelfReconnectGapRecord?
    /// OBS R2 incident-ledger timeline, read app-side from the shared app group.
    /// Diagnostic-only; folded into `incident`.
    public let recentIncidents: [IncidentLedgerRecord]

    /// Creates a bundle by storing user context and the supplied diagnostic snapshots.
    public init(
        reportID: UUID = UUID(),
        context: BugReportContext,
        app: BugReportAppSnapshot,
        device: BugReportDeviceSnapshot,
        vpn: BugReportVPNSnapshot,
        filters: BugReportFilterSummary,
        diagnostics: DiagnosticsStore,
        localHistoryEnabled: Bool,
        debugLogEntries: [BugReportDebugLogEntry],
        selfReconnectTimes: [Date] = [],
        lastFocusSwitch: FocusSwitchDiagnosticRecord? = nil,
        selfReconnectGap: SelfReconnectGapRecord? = nil,
        recentIncidents: [IncidentLedgerRecord] = []
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
        self.selfReconnectTimes = selfReconnectTimes
        self.lastFocusSwitch = lastFocusSwitch
        self.selfReconnectGap = selfReconnectGap
        self.recentIncidents = recentIncidents
    }

    /// The redacted recovery/escalation envelope surfaced in the report (LAV-94 B).
    package var incident: BugReportIncidentSummary {
        BugReportIncidentSummary(
            health: vpn.health,
            selfReconnectTimes: selfReconnectTimes,
            lastFocusSwitch: lastFocusSwitch,
            selfReconnectGap: selfReconnectGap,
            recentIncidents: recentIncidents
        )
    }

    /// Ordered disclosure sections shown before the user submits optional diagnostics.
    public var previewSections: [BugReportPreviewSection] {
        [
            whatHappenedSection,
            appDeviceSection,
            vpnStatusSection,
            lifecycleLogSection,
            networkResolverSection,
            incidentSummarySection,
            filterSnapshotSection,
            localActivitySection
        ]
    }

    /// Builds the backend request body, attaching diagnostic sections only when the user opted in.
    public func makeRequestBody() -> [String: Any] {
        let incident = incident
        var body: [String: Any] = [
            "report_id": reportID.uuidString.lowercased(),
            "include_recent_dns_events": false,
            // Honest replacement for the always-false `has_recent_dns_events`: true only when
            // diagnostics are attached AND there is recovery evidence to read (LAV-94 B).
            "has_incident_summary": context.includeDiagnostics && incident.hasContent,
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
            body["incident"] = incident.dictionary
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

    private var incidentSummarySection: BugReportPreviewSection {
        let incident = incident
        var items = [
            item("self_reconnects", "Self-reconnects (recent)", "\(incident.selfReconnectCount)"),
            item(
                "last_self_reconnect",
                "Last self-reconnect",
                incident.lastSelfReconnectAt.map(Self.displayDate) ?? "None recorded"
            ),
            item("incident_last_failure", "Last failure reason", incident.lastFailureReason ?? "None"),
            item("consecutive_smoke_failures", "Consecutive smoke-probe failures", "\(incident.consecutiveDNSSmokeProbeFailureCount)"),
            item("rejected_responses", "Rejected resolver responses", "\(incident.consecutiveRejectedSmokeResponseCount)"),
            item(
                "encrypted_fallback_serving",
                "Encrypted fallback last served",
                incident.lastEncryptedFallbackSuccessAt.map(Self.displayDate) ?? "Not serving"
            ),
            item("runtime_resets", "Resolver runtime resets", "\(incident.resolverRuntimeResetCount)"),
            item(
                "self_reconnect_gap",
                "Last protection gap",
                incident.selfReconnectGap.map { gap in
                    if let gapMilliseconds = gap.gapMilliseconds {
                        "\(Self.displayDate(gap.startedAt)) (\(gapMilliseconds) ms)"
                    } else {
                        "\(Self.displayDate(gap.startedAt)) (still open)"
                    }
                } ?? "None recorded"
            )
        ]

        if let resetReason = incident.lastResolverRuntimeResetReason {
            items.append(item("last_runtime_reset_reason", "Last runtime reset reason", resetReason))
        }

        return BugReportPreviewSection(
            id: "incident_summary",
            title: "Incident Summary",
            purpose: "A redacted recovery timeline — self-reconnects, failure reasons, and fallback state. No browsing history or domains are included.",
            items: items
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

    private static func displayDate(_ date: Date) -> String {
        SharedDateFormatting.iso8601.string(from: date)
    }
}

/// Chooses whether a prepared draft still matches the context being submitted.
public enum BugReportSubmissionBundlePolicy {
    /// Reuses a matching draft; otherwise invokes the factory and returns a fresh bundle.
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
