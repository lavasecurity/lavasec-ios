import Foundation

/// Broad network-path categories recorded in tunnel health state.
public enum TunnelNetworkKind: String, Codable, Sendable {
    /// The current network kind is unavailable or has not been classified.
    case unknown
    /// The tunnel is using a Wi-Fi network path.
    case wifi
    /// The tunnel is using a cellular network path.
    case cellular
    /// The tunnel is using a wired network path.
    case wired
    /// The tunnel is using a known path outside the named categories.
    case other
}

/// A serializable snapshot of tunnel connectivity, resolver, and recovery health.
public struct TunnelHealthSnapshot: Codable, Equatable, Sendable {
    /// The time at which this health observation period began.
    public var startedAt: Date
    /// The time of the most recent snapshot update.
    public var updatedAt: Date
    /// The current broad network-path category.
    public var networkKind: TunnelNetworkKind
    /// The most recently recorded resolver address, if available.
    public var lastResolverAddress: String?
    /// The most recently recorded upstream failure reason label.
    public var lastFailureReason: String?
    /// The number of DNS cache hits recorded in this observation period.
    public var cacheHitCount: Int
    /// The number of DNS cache misses recorded in this observation period.
    public var cacheMissCount: Int
    /// The number of DNS queries combined with an in-flight equivalent query.
    public var coalescedQueryCount: Int
    /// The number of successful upstream resolutions recorded.
    public var upstreamSuccessCount: Int
    /// The number of failed upstream resolutions recorded.
    public var upstreamFailureCount: Int
    /// The current streak of consecutive upstream failures.
    public var consecutiveUpstreamFailureCount: Int
    /// The transport used for the most recently recorded resolver operation.
    public var lastResolverTransport: DNSResolverTransport
    /// The number of DNS-over-HTTPS HTTP failures recorded.
    public var dohHTTPFailureCount: Int
    /// ALPN id of the last successful DoH negotiation ("h3", "h2", "http/1.1").
    public var lastDoHHTTPVersion: String?
    /// The number of recorded upstream timeouts.
    public var upstreamTimeoutCount: Int
    /// The number of truncated UDP DNS responses recorded.
    public var udpTruncatedResponseCount: Int
    /// The number of TCP fallback attempts recorded.
    public var tcpFallbackAttemptCount: Int
    /// The number of successful TCP fallback attempts.
    public var tcpFallbackSuccessCount: Int
    /// The number of Device DNS fallback attempts.
    public var deviceDNSFallbackAttemptCount: Int
    /// The number of successful Device DNS fallback attempts.
    public var deviceDNSFallbackSuccessCount: Int
    /// The number of observations in which Device DNS was unavailable.
    public var deviceDNSUnavailableCount: Int
    /// Whether the most recently observed network path was satisfied.
    public var networkPathIsSatisfied: Bool
    /// The time of the most recent DNS smoke probe, if one has run.
    public var lastDNSSmokeProbeAt: Date?
    /// The outcome of the most recent DNS smoke probe, if one has run.
    public var lastDNSSmokeProbeSucceeded: Bool?
    /// The number of successful DNS smoke probes recorded.
    public var dnsSmokeProbeSuccessCount: Int
    /// The number of failed DNS smoke probes recorded.
    public var dnsSmokeProbeFailureCount: Int
    /// Consecutive failed DNS smoke probes, reset only by a smoke-probe success.
    /// Unlike `consecutiveUpstreamFailureCount` this is NOT reset by forwarding /
    /// encrypted-fallback successes or self-reconnects, so a primary resolver that
    /// keeps failing its health probe can't be masked "healthy" by incidental
    /// fallback-carried traffic — the signal the connectivity policy escalates on.
    public var consecutiveDNSSmokeProbeFailureCount: Int
    /// Consecutive smoke probes that returned a REACHABLE-but-rejected answer
    /// (`rejected-response`) from the SAME resolver identity. Unlike
    /// `consecutiveDNSSmokeProbeFailureCount` this is resolver-identity-scoped and is
    /// deliberately kept OUT of every recovery reset path — network-change recovery, the
    /// device-DNS settle/recapture churn, wake, AND the organic forwarding path (where a
    /// REFUSED reply counts as `didResolve`). It is cleared only by an accepted primary
    /// smoke-probe success or a resolver change. A churny roaming network kept the generic streak
    /// pinned under the reconnect threshold so a steadily hijacking/stale resolver never
    /// escalated (UR-37 / LAV-87); this survives that churn so recovery can engage.
    public var consecutiveRejectedSmokeResponseCount: Int
    /// The resolver identity (`primaryCacheIdentifier` — the primary alone, without the
    /// fallback components that churn on handoff) the rejected-response streak is counting,
    /// so a handoff to a different resolver restarts the count instead of carrying it over.
    public var rejectedSmokeResponseResolverIdentity: String?
    /// Times the rejected-response streak was re-keyed to a different resolver identity this
    /// session. QA instrument for the identity scoping: during a steady-hijacker replay this
    /// stays frozen while the streak climbs to the escalation threshold.
    public var rejectedSmokeResponseRescopeCount: Int
    /// Whether Device DNS fallback mode is currently active.
    public var deviceDNSFallbackModeActive: Bool
    /// The most recent time Device DNS fallback mode was activated.
    public var lastDeviceDNSFallbackActivatedAt: Date?
    /// The number of Device DNS fallback mode activations recorded.
    public var deviceDNSFallbackActivationCount: Int
    /// Resolution attempt counts keyed by resolver address.
    public var resolverAttemptCounts: [String: Int]
    /// Successful resolution counts keyed by resolver address.
    public var resolverSuccessCounts: [String: Int]
    /// Failed resolution counts keyed by resolver address.
    public var resolverFailureCounts: [String: Int]
    /// The time of the most recently recorded network change.
    public var lastNetworkChangeAt: Date?
    /// The number of network changes recorded.
    public var networkChangeCount: Int
    /// The time of the most recent resolver runtime reset.
    public var lastResolverRuntimeResetAt: Date?
    /// The reason label for the most recent resolver runtime reset.
    public var lastResolverRuntimeResetReason: String?
    /// The instant the configured resolver IDENTITY actually changed (a different upstream),
    /// distinct from `lastResolverRuntimeResetAt`, which is also bumped by same-resolver runtime
    /// resets (snapshot reloads, pause/resume, recovery). Only a genuine identity change is a fresh
    /// DNS-health context, so this — not the broad reset timestamp — anchors the smoke-probe /
    /// encrypted-fallback coverage baseline.
    public var lastResolverIdentityChangeAt: Date?
    /// The number of resolver runtime resets recorded.
    public var resolverRuntimeResetCount: Int
    /// The time of the most recent successful upstream resolution on any path.
    public var lastUpstreamSuccessAt: Date?
    /// Timestamp of the last forwarding success carried by the configured PRIMARY
    /// upstream (i.e. not the encrypted Device-DNS safety net). The silent recovery
    /// banner-clear keys off this rather than `lastUpstreamSuccessAt` so a query
    /// that only resolved because the encrypted fallback caught it does not clear
    /// the "reconnect" banner while the primary remains wedged and traffic still
    /// depends on the safety net.
    public var lastPrimaryUpstreamSuccessAt: Date?
    /// Timestamp of the last DNS forwarding success carried by the ENCRYPTED safety net
    /// (the DoH/DoT fallback for a device-DNS-primary config). Set ONLY when a query
    /// resolved via that encrypted fallback. The connectivity policy reads this to
    /// recognise the encrypted fallback is actively serving DNS, so a transition-induced
    /// primary-resolver staleness does not warrant a user-visible self-reconnect. Kept
    /// deliberately SEPARATE from `lastPrimaryUpstreamSuccessAt` (never set in the same
    /// branch) so fallback-carried traffic can't paint the wedged primary "healthy".
    public var lastEncryptedFallbackSuccessAt: Date?
    /// The time of the most recent failed upstream resolution.
    public var lastUpstreamFailureAt: Date?
    /// The duration, in milliseconds, of the most recently timed upstream operation.
    /// Set for failures/timeouts too, so this is a raw "what just happened" value — the
    /// user-facing "Last DNS response" row uses `lastUpstreamSuccessDurationMilliseconds`.
    public var lastUpstreamDurationMilliseconds: Int?
    /// The round-trip duration, in milliseconds, of the most recent *successful* upstream
    /// resolution. Distinct from `lastUpstreamDurationMilliseconds` so the "Last DNS
    /// response" row never reports a timeout's duration as a response (LAV-119).
    public var lastUpstreamSuccessDurationMilliseconds: Int?
    /// Session-cumulative histogram of upstream round-trip durations, backing the Nerd
    /// Stats p50/p90/p95 rows (plans/2026-07-11-nerd-stats-dns-latency-plan.md).
    public var upstreamLatencyHistogram: DNSLatencyHistogram
    /// The number of upstream responses classified as slow.
    public var slowUpstreamResponseCount: Int
    /// The current streak of upstream responses classified as slow.
    public var consecutiveSlowUpstreamResponseCount: Int
    /// The time of the most recent upstream response classified as slow.
    public var lastSlowUpstreamResponseAt: Date?
    /// The time of the most recent network-settings reapply failure.
    public var lastNetworkSettingsReapplyFailureAt: Date?
    /// The reason label for the most recent network-settings reapply failure.
    public var lastNetworkSettingsReapplyFailureReason: String?
    /// The number of network-settings reapply failures recorded.
    public var networkSettingsReapplyFailureCount: Int
    /// Queries served fail-closed (`.protectionUnavailable`) this session. Deliberately kept
    /// OUT of user-facing filtering counts and Domain History (a fail-closed block is not a
    /// blocklist match — #164 honesty rule); without a health-side trace, a past fail-closed
    /// window is indistinguishable from "no incident" in a field report.
    public var failClosedServedQueryCount: Int
    /// The most recent time a query was served fail-closed.
    public var lastFailClosedAt: Date?
    /// "snapshot-unavailable" (no usable snapshot could be loaded/compiled — a restart cannot
    /// fix it) vs "transient-protection-unavailable" (e.g. the cold-start bootstrap window
    /// while the real snapshot decodes).
    public var lastFailClosedReason: String?

    private enum CodingKeys: String, CodingKey {
        case startedAt
        case updatedAt
        case networkKind
        case lastResolverAddress
        case lastFailureReason
        case cacheHitCount
        case cacheMissCount
        case coalescedQueryCount
        case upstreamSuccessCount
        case upstreamFailureCount
        case consecutiveUpstreamFailureCount
        case lastResolverTransport
        case dohHTTPFailureCount
        case lastDoHHTTPVersion
        case upstreamTimeoutCount
        case udpTruncatedResponseCount
        case tcpFallbackAttemptCount
        case tcpFallbackSuccessCount
        case deviceDNSFallbackAttemptCount
        case deviceDNSFallbackSuccessCount
        case deviceDNSUnavailableCount
        case networkPathIsSatisfied
        case lastDNSSmokeProbeAt
        case lastDNSSmokeProbeSucceeded
        case dnsSmokeProbeSuccessCount
        case dnsSmokeProbeFailureCount
        case consecutiveDNSSmokeProbeFailureCount
        case consecutiveRejectedSmokeResponseCount
        case rejectedSmokeResponseResolverIdentity
        case rejectedSmokeResponseRescopeCount
        case deviceDNSFallbackModeActive
        case lastDeviceDNSFallbackActivatedAt
        case deviceDNSFallbackActivationCount
        case resolverAttemptCounts
        case resolverSuccessCounts
        case resolverFailureCounts
        case lastNetworkChangeAt
        case networkChangeCount
        case lastResolverRuntimeResetAt
        case lastResolverRuntimeResetReason
        case lastResolverIdentityChangeAt
        case resolverRuntimeResetCount
        case lastUpstreamSuccessAt
        case lastPrimaryUpstreamSuccessAt
        case lastEncryptedFallbackSuccessAt
        case lastUpstreamFailureAt
        case lastUpstreamDurationMilliseconds
        case lastUpstreamSuccessDurationMilliseconds
        case upstreamLatencyHistogram
        case slowUpstreamResponseCount
        case consecutiveSlowUpstreamResponseCount
        case lastSlowUpstreamResponseAt
        case lastNetworkSettingsReapplyFailureAt
        case lastNetworkSettingsReapplyFailureReason
        case networkSettingsReapplyFailureCount
        case failClosedServedQueryCount
        case lastFailClosedAt
        case lastFailClosedReason
    }

    /// Creates a snapshot from explicit health timestamps, counters, and status fields.
    public init(
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        networkKind: TunnelNetworkKind = .unknown,
        lastResolverAddress: String? = nil,
        lastFailureReason: String? = nil,
        cacheHitCount: Int = 0,
        cacheMissCount: Int = 0,
        coalescedQueryCount: Int = 0,
        upstreamSuccessCount: Int = 0,
        upstreamFailureCount: Int = 0,
        consecutiveUpstreamFailureCount: Int = 0,
        lastResolverTransport: DNSResolverTransport = .plainDNS,
        dohHTTPFailureCount: Int = 0,
        lastDoHHTTPVersion: String? = nil,
        upstreamTimeoutCount: Int = 0,
        udpTruncatedResponseCount: Int = 0,
        tcpFallbackAttemptCount: Int = 0,
        tcpFallbackSuccessCount: Int = 0,
        deviceDNSFallbackAttemptCount: Int = 0,
        deviceDNSFallbackSuccessCount: Int = 0,
        deviceDNSUnavailableCount: Int = 0,
        networkPathIsSatisfied: Bool = true,
        lastDNSSmokeProbeAt: Date? = nil,
        lastDNSSmokeProbeSucceeded: Bool? = nil,
        dnsSmokeProbeSuccessCount: Int = 0,
        dnsSmokeProbeFailureCount: Int = 0,
        consecutiveDNSSmokeProbeFailureCount: Int = 0,
        consecutiveRejectedSmokeResponseCount: Int = 0,
        rejectedSmokeResponseResolverIdentity: String? = nil,
        rejectedSmokeResponseRescopeCount: Int = 0,
        deviceDNSFallbackModeActive: Bool = false,
        lastDeviceDNSFallbackActivatedAt: Date? = nil,
        deviceDNSFallbackActivationCount: Int = 0,
        resolverAttemptCounts: [String: Int] = [:],
        resolverSuccessCounts: [String: Int] = [:],
        resolverFailureCounts: [String: Int] = [:],
        lastNetworkChangeAt: Date? = nil,
        networkChangeCount: Int = 0,
        lastResolverRuntimeResetAt: Date? = nil,
        lastResolverRuntimeResetReason: String? = nil,
        lastResolverIdentityChangeAt: Date? = nil,
        resolverRuntimeResetCount: Int = 0,
        lastUpstreamSuccessAt: Date? = nil,
        lastPrimaryUpstreamSuccessAt: Date? = nil,
        lastEncryptedFallbackSuccessAt: Date? = nil,
        lastUpstreamFailureAt: Date? = nil,
        lastUpstreamDurationMilliseconds: Int? = nil,
        lastUpstreamSuccessDurationMilliseconds: Int? = nil,
        upstreamLatencyHistogram: DNSLatencyHistogram = DNSLatencyHistogram(),
        slowUpstreamResponseCount: Int = 0,
        consecutiveSlowUpstreamResponseCount: Int = 0,
        lastSlowUpstreamResponseAt: Date? = nil,
        lastNetworkSettingsReapplyFailureAt: Date? = nil,
        lastNetworkSettingsReapplyFailureReason: String? = nil,
        networkSettingsReapplyFailureCount: Int = 0,
        failClosedServedQueryCount: Int = 0,
        lastFailClosedAt: Date? = nil,
        lastFailClosedReason: String? = nil
    ) {
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.networkKind = networkKind
        self.lastResolverAddress = lastResolverAddress
        self.lastFailureReason = lastFailureReason
        self.cacheHitCount = cacheHitCount
        self.cacheMissCount = cacheMissCount
        self.coalescedQueryCount = coalescedQueryCount
        self.upstreamSuccessCount = upstreamSuccessCount
        self.upstreamFailureCount = upstreamFailureCount
        self.consecutiveUpstreamFailureCount = consecutiveUpstreamFailureCount
        self.lastResolverTransport = lastResolverTransport
        self.dohHTTPFailureCount = dohHTTPFailureCount
        self.lastDoHHTTPVersion = lastDoHHTTPVersion
        self.upstreamTimeoutCount = upstreamTimeoutCount
        self.udpTruncatedResponseCount = udpTruncatedResponseCount
        self.tcpFallbackAttemptCount = tcpFallbackAttemptCount
        self.tcpFallbackSuccessCount = tcpFallbackSuccessCount
        self.deviceDNSFallbackAttemptCount = deviceDNSFallbackAttemptCount
        self.deviceDNSFallbackSuccessCount = deviceDNSFallbackSuccessCount
        self.deviceDNSUnavailableCount = deviceDNSUnavailableCount
        self.networkPathIsSatisfied = networkPathIsSatisfied
        self.lastDNSSmokeProbeAt = lastDNSSmokeProbeAt
        self.lastDNSSmokeProbeSucceeded = lastDNSSmokeProbeSucceeded
        self.dnsSmokeProbeSuccessCount = dnsSmokeProbeSuccessCount
        self.dnsSmokeProbeFailureCount = dnsSmokeProbeFailureCount
        self.consecutiveDNSSmokeProbeFailureCount = consecutiveDNSSmokeProbeFailureCount
        self.consecutiveRejectedSmokeResponseCount = consecutiveRejectedSmokeResponseCount
        self.rejectedSmokeResponseResolverIdentity = rejectedSmokeResponseResolverIdentity
        self.rejectedSmokeResponseRescopeCount = rejectedSmokeResponseRescopeCount
        self.deviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        self.lastDeviceDNSFallbackActivatedAt = lastDeviceDNSFallbackActivatedAt
        self.deviceDNSFallbackActivationCount = deviceDNSFallbackActivationCount
        self.resolverAttemptCounts = resolverAttemptCounts
        self.resolverSuccessCounts = resolverSuccessCounts
        self.resolverFailureCounts = resolverFailureCounts
        self.lastNetworkChangeAt = lastNetworkChangeAt
        self.networkChangeCount = networkChangeCount
        self.lastResolverRuntimeResetAt = lastResolverRuntimeResetAt
        self.lastResolverRuntimeResetReason = lastResolverRuntimeResetReason
        self.lastResolverIdentityChangeAt = lastResolverIdentityChangeAt
        self.resolverRuntimeResetCount = resolverRuntimeResetCount
        self.lastUpstreamSuccessAt = lastUpstreamSuccessAt
        self.lastPrimaryUpstreamSuccessAt = lastPrimaryUpstreamSuccessAt
        self.lastEncryptedFallbackSuccessAt = lastEncryptedFallbackSuccessAt
        self.lastUpstreamFailureAt = lastUpstreamFailureAt
        self.lastUpstreamDurationMilliseconds = lastUpstreamDurationMilliseconds
        self.lastUpstreamSuccessDurationMilliseconds = lastUpstreamSuccessDurationMilliseconds
        self.upstreamLatencyHistogram = upstreamLatencyHistogram
        self.slowUpstreamResponseCount = slowUpstreamResponseCount
        self.consecutiveSlowUpstreamResponseCount = consecutiveSlowUpstreamResponseCount
        self.lastSlowUpstreamResponseAt = lastSlowUpstreamResponseAt
        self.lastNetworkSettingsReapplyFailureAt = lastNetworkSettingsReapplyFailureAt
        self.lastNetworkSettingsReapplyFailureReason = lastNetworkSettingsReapplyFailureReason
        self.networkSettingsReapplyFailureCount = networkSettingsReapplyFailureCount
        self.failClosedServedQueryCount = failClosedServedQueryCount
        self.lastFailClosedAt = lastFailClosedAt
        self.lastFailClosedReason = lastFailClosedReason
    }

    /// Decodes a snapshot, defaulting health fields absent from older payloads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.networkKind = try container.decode(TunnelNetworkKind.self, forKey: .networkKind)
        self.lastResolverAddress = try container.decodeIfPresent(String.self, forKey: .lastResolverAddress)
        self.lastFailureReason = try container.decodeIfPresent(String.self, forKey: .lastFailureReason)
        self.cacheHitCount = try container.decodeIfPresent(Int.self, forKey: .cacheHitCount) ?? 0
        self.cacheMissCount = try container.decodeIfPresent(Int.self, forKey: .cacheMissCount) ?? 0
        self.coalescedQueryCount = try container.decodeIfPresent(Int.self, forKey: .coalescedQueryCount) ?? 0
        self.upstreamSuccessCount = try container.decodeIfPresent(Int.self, forKey: .upstreamSuccessCount) ?? 0
        self.upstreamFailureCount = try container.decodeIfPresent(Int.self, forKey: .upstreamFailureCount) ?? 0
        self.consecutiveUpstreamFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveUpstreamFailureCount
        ) ?? 0
        self.lastResolverTransport = try container.decodeIfPresent(
            DNSResolverTransport.self,
            forKey: .lastResolverTransport
        ) ?? .plainDNS
        self.dohHTTPFailureCount = try container.decodeIfPresent(Int.self, forKey: .dohHTTPFailureCount) ?? 0
        self.lastDoHHTTPVersion = try container.decodeIfPresent(String.self, forKey: .lastDoHHTTPVersion)
        self.upstreamTimeoutCount = try container.decodeIfPresent(Int.self, forKey: .upstreamTimeoutCount) ?? 0
        self.udpTruncatedResponseCount = try container.decodeIfPresent(Int.self, forKey: .udpTruncatedResponseCount) ?? 0
        self.tcpFallbackAttemptCount = try container.decodeIfPresent(Int.self, forKey: .tcpFallbackAttemptCount) ?? 0
        self.tcpFallbackSuccessCount = try container.decodeIfPresent(Int.self, forKey: .tcpFallbackSuccessCount) ?? 0
        self.deviceDNSFallbackAttemptCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSFallbackAttemptCount
        ) ?? 0
        self.deviceDNSFallbackSuccessCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSFallbackSuccessCount
        ) ?? 0
        self.deviceDNSUnavailableCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSUnavailableCount
        ) ?? 0
        self.networkPathIsSatisfied = try container.decodeIfPresent(
            Bool.self,
            forKey: .networkPathIsSatisfied
        ) ?? true
        self.lastDNSSmokeProbeAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastDNSSmokeProbeAt
        )
        self.lastDNSSmokeProbeSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .lastDNSSmokeProbeSucceeded
        )
        self.dnsSmokeProbeSuccessCount = try container.decodeIfPresent(
            Int.self,
            forKey: .dnsSmokeProbeSuccessCount
        ) ?? 0
        self.dnsSmokeProbeFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .dnsSmokeProbeFailureCount
        ) ?? 0
        self.consecutiveDNSSmokeProbeFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveDNSSmokeProbeFailureCount
        ) ?? 0
        self.consecutiveRejectedSmokeResponseCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveRejectedSmokeResponseCount
        ) ?? 0
        self.rejectedSmokeResponseResolverIdentity = try container.decodeIfPresent(
            String.self,
            forKey: .rejectedSmokeResponseResolverIdentity
        )
        self.rejectedSmokeResponseRescopeCount = try container.decodeIfPresent(
            Int.self,
            forKey: .rejectedSmokeResponseRescopeCount
        ) ?? 0
        self.deviceDNSFallbackModeActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .deviceDNSFallbackModeActive
        ) ?? false
        self.lastDeviceDNSFallbackActivatedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastDeviceDNSFallbackActivatedAt
        )
        self.deviceDNSFallbackActivationCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSFallbackActivationCount
        ) ?? 0
        self.resolverAttemptCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .resolverAttemptCounts
        ) ?? [:]
        self.resolverSuccessCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .resolverSuccessCounts
        ) ?? [:]
        self.resolverFailureCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .resolverFailureCounts
        ) ?? [:]
        self.lastNetworkChangeAt = try container.decodeIfPresent(Date.self, forKey: .lastNetworkChangeAt)
        self.networkChangeCount = try container.decodeIfPresent(Int.self, forKey: .networkChangeCount) ?? 0
        self.lastResolverRuntimeResetAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastResolverRuntimeResetAt
        )
        self.lastResolverRuntimeResetReason = try container.decodeIfPresent(
            String.self,
            forKey: .lastResolverRuntimeResetReason
        )
        self.lastResolverIdentityChangeAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastResolverIdentityChangeAt
        )
        self.resolverRuntimeResetCount = try container.decodeIfPresent(
            Int.self,
            forKey: .resolverRuntimeResetCount
        ) ?? 0
        self.lastUpstreamSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastUpstreamSuccessAt)
        self.lastPrimaryUpstreamSuccessAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastPrimaryUpstreamSuccessAt
        )
        self.lastEncryptedFallbackSuccessAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastEncryptedFallbackSuccessAt
        )
        self.lastUpstreamFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastUpstreamFailureAt)
        self.lastUpstreamDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .lastUpstreamDurationMilliseconds
        )
        self.lastUpstreamSuccessDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .lastUpstreamSuccessDurationMilliseconds
        )
        self.upstreamLatencyHistogram = try container.decodeIfPresent(
            DNSLatencyHistogram.self,
            forKey: .upstreamLatencyHistogram
        ) ?? DNSLatencyHistogram()
        self.slowUpstreamResponseCount = try container.decodeIfPresent(
            Int.self,
            forKey: .slowUpstreamResponseCount
        ) ?? 0
        self.consecutiveSlowUpstreamResponseCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveSlowUpstreamResponseCount
        ) ?? 0
        self.lastSlowUpstreamResponseAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastSlowUpstreamResponseAt
        )
        self.lastNetworkSettingsReapplyFailureAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastNetworkSettingsReapplyFailureAt
        )
        self.lastNetworkSettingsReapplyFailureReason = try container.decodeIfPresent(
            String.self,
            forKey: .lastNetworkSettingsReapplyFailureReason
        )
        self.networkSettingsReapplyFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .networkSettingsReapplyFailureCount
        ) ?? 0
        self.failClosedServedQueryCount = try container.decodeIfPresent(
            Int.self,
            forKey: .failClosedServedQueryCount
        ) ?? 0
        self.lastFailClosedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastFailClosedAt
        )
        self.lastFailClosedReason = try container.decodeIfPresent(
            String.self,
            forKey: .lastFailClosedReason
        )
    }

    /// The combined cache hit and miss count.
    public var totalCacheLookups: Int {
        cacheHitCount + cacheMissCount
    }

    /// The fraction of cache lookups that hit, or zero when no lookups were recorded.
    public var cacheHitRate: Double {
        guard totalCacheLookups > 0 else {
            return 0
        }

        return Double(cacheHitCount) / Double(totalCacheLookups)
    }

    /// The fraction of TCP fallback attempts that succeeded, or zero with no attempts.
    public var tcpFallbackSuccessRate: Double {
        guard tcpFallbackAttemptCount > 0 else {
            return 0
        }

        return Double(tcpFallbackSuccessCount) / Double(tcpFallbackAttemptCount)
    }

    /// The fraction of Device DNS fallback attempts that succeeded, or zero with no attempts.
    public var deviceDNSFallbackSuccessRate: Double {
        guard deviceDNSFallbackAttemptCount > 0 else {
            return 0
        }

        return Double(deviceDNSFallbackSuccessCount) / Double(deviceDNSFallbackAttemptCount)
    }
}
