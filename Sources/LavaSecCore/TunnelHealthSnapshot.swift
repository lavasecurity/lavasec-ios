import Foundation

public enum TunnelNetworkKind: String, Codable, Sendable {
    case unknown
    case wifi
    case cellular
    case wired
    case other
}

public struct TunnelHealthSnapshot: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var updatedAt: Date
    public var networkKind: TunnelNetworkKind
    public var lastResolverAddress: String?
    public var lastFailureReason: String?
    public var cacheHitCount: Int
    public var cacheMissCount: Int
    public var coalescedQueryCount: Int
    public var upstreamSuccessCount: Int
    public var upstreamFailureCount: Int
    public var consecutiveUpstreamFailureCount: Int
    public var lastResolverTransport: DNSResolverTransport
    public var dohHTTPFailureCount: Int
    /// ALPN id of the last successful DoH negotiation ("h3", "h2", "http/1.1").
    public var lastDoHHTTPVersion: String?
    public var upstreamTimeoutCount: Int
    public var udpTruncatedResponseCount: Int
    public var tcpFallbackAttemptCount: Int
    public var tcpFallbackSuccessCount: Int
    public var deviceDNSFallbackAttemptCount: Int
    public var deviceDNSFallbackSuccessCount: Int
    public var deviceDNSUnavailableCount: Int
    public var networkPathIsSatisfied: Bool
    public var lastDNSSmokeProbeAt: Date?
    public var lastDNSSmokeProbeSucceeded: Bool?
    public var dnsSmokeProbeSuccessCount: Int
    public var dnsSmokeProbeFailureCount: Int
    public var deviceDNSFallbackModeActive: Bool
    public var lastDeviceDNSFallbackActivatedAt: Date?
    public var deviceDNSFallbackActivationCount: Int
    public var resolverAttemptCounts: [String: Int]
    public var resolverSuccessCounts: [String: Int]
    public var resolverFailureCounts: [String: Int]
    public var lastNetworkChangeAt: Date?
    public var networkChangeCount: Int
    public var lastResolverRuntimeResetAt: Date?
    public var lastResolverRuntimeResetReason: String?
    public var resolverRuntimeResetCount: Int
    public var lastUpstreamSuccessAt: Date?
    public var lastUpstreamFailureAt: Date?
    public var lastUpstreamDurationMilliseconds: Int?
    public var slowUpstreamResponseCount: Int
    public var consecutiveSlowUpstreamResponseCount: Int
    public var lastSlowUpstreamResponseAt: Date?
    public var lastNetworkSettingsReapplyFailureAt: Date?
    public var lastNetworkSettingsReapplyFailureReason: String?
    public var networkSettingsReapplyFailureCount: Int

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
        case resolverRuntimeResetCount
        case lastUpstreamSuccessAt
        case lastUpstreamFailureAt
        case lastUpstreamDurationMilliseconds
        case slowUpstreamResponseCount
        case consecutiveSlowUpstreamResponseCount
        case lastSlowUpstreamResponseAt
        case lastNetworkSettingsReapplyFailureAt
        case lastNetworkSettingsReapplyFailureReason
        case networkSettingsReapplyFailureCount
    }

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
        resolverRuntimeResetCount: Int = 0,
        lastUpstreamSuccessAt: Date? = nil,
        lastUpstreamFailureAt: Date? = nil,
        lastUpstreamDurationMilliseconds: Int? = nil,
        slowUpstreamResponseCount: Int = 0,
        consecutiveSlowUpstreamResponseCount: Int = 0,
        lastSlowUpstreamResponseAt: Date? = nil,
        lastNetworkSettingsReapplyFailureAt: Date? = nil,
        lastNetworkSettingsReapplyFailureReason: String? = nil,
        networkSettingsReapplyFailureCount: Int = 0
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
        self.resolverRuntimeResetCount = resolverRuntimeResetCount
        self.lastUpstreamSuccessAt = lastUpstreamSuccessAt
        self.lastUpstreamFailureAt = lastUpstreamFailureAt
        self.lastUpstreamDurationMilliseconds = lastUpstreamDurationMilliseconds
        self.slowUpstreamResponseCount = slowUpstreamResponseCount
        self.consecutiveSlowUpstreamResponseCount = consecutiveSlowUpstreamResponseCount
        self.lastSlowUpstreamResponseAt = lastSlowUpstreamResponseAt
        self.lastNetworkSettingsReapplyFailureAt = lastNetworkSettingsReapplyFailureAt
        self.lastNetworkSettingsReapplyFailureReason = lastNetworkSettingsReapplyFailureReason
        self.networkSettingsReapplyFailureCount = networkSettingsReapplyFailureCount
    }

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
        self.resolverRuntimeResetCount = try container.decodeIfPresent(
            Int.self,
            forKey: .resolverRuntimeResetCount
        ) ?? 0
        self.lastUpstreamSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastUpstreamSuccessAt)
        self.lastUpstreamFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastUpstreamFailureAt)
        self.lastUpstreamDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .lastUpstreamDurationMilliseconds
        )
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
    }

    public var totalCacheLookups: Int {
        cacheHitCount + cacheMissCount
    }

    public var cacheHitRate: Double {
        guard totalCacheLookups > 0 else {
            return 0
        }

        return Double(cacheHitCount) / Double(totalCacheLookups)
    }

    public var tcpFallbackSuccessRate: Double {
        guard tcpFallbackAttemptCount > 0 else {
            return 0
        }

        return Double(tcpFallbackSuccessCount) / Double(tcpFallbackAttemptCount)
    }

    public var deviceDNSFallbackSuccessRate: Double {
        guard deviceDNSFallbackAttemptCount > 0 else {
            return 0
        }

        return Double(deviceDNSFallbackSuccessCount) / Double(deviceDNSFallbackAttemptCount)
    }
}
