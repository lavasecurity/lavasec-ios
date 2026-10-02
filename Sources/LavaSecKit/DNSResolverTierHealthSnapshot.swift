import Foundation

/// The user's canonical resolver tiers, preserved across DNS-only and chained execution.
public enum DNSResolverTier: String, CaseIterable, Codable, Sendable {
    /// The chained upstream's resolver, present only while chaining is latched.
    case tierZero
    /// The user's selected primary resolver.
    case tierOne
    /// The user's selected optional fallback resolver.
    case tierTwo
}

/// Privacy-safe observations and repair admission for one configured DNS tier.
///
/// Endpoint addresses, queried names and network identifiers are deliberately absent. A
/// configuration identity, when supplied, must be opaque; it fences observations to the
/// running selection without publishing a custom endpoint in a diagnostic report.
public struct DNSResolverTierHealthSnapshot: Codable, Equatable, Sendable {
    /// The source of this tier's configured resolver.
    public enum ResolverKind: String, Codable, Sendable {
        /// A resolver configured by the chained upstream.
        case upstream
        /// The resolver addresses captured from the current device network.
        case device
        /// A selected preset or custom endpoint independent of device DNS capture.
        case fixed
    }

    /// The admitted egress of this tier's resolver attempt.
    public enum Egress: String, Codable, Sendable {
        /// The attempt follows the chained upstream route.
        case tunnel
        /// The attempt follows the permitted physical network route.
        case physical
        /// The tier attempted endpoints on both physical and upstream routes.
        case mixed
    }

    /// What this tier, independently of the other tiers, most recently established.
    public enum Outcome: String, Codable, Sendable {
        /// A valid answer, including authoritative negative answers, served the lookup.
        case served
        /// The resolver replied without serving the lookup.
        case answered
        /// An admitted resolver attempt failed.
        case failure
        /// No resolver attempt supplied failure or service evidence.
        case notAttempted
    }

    /// The repair this tier's resolver source can support.
    public enum RecoveryKind: String, Codable, Sendable {
        /// The upstream session's recovery owner handles this tier.
        case upstreamSession
        /// The selected endpoint can be retried without recapturing device DNS.
        case retryFixedEndpoint
        /// A bounded cold reconnect can recapture device DNS.
        case recaptureDeviceDNS
        /// No tier-specific repair is requested.
        case none
    }

    /// The current admission or progress of the tier's repair.
    public enum RecoveryStatus: String, Codable, Sendable {
        /// The latest evidence requires no repair.
        case notNeeded
        /// More evidence or a usable network is required before repair.
        case waiting
        /// The tier's evidence permits its repair to be considered.
        case eligible
        /// The fixed resolver endpoint is being retried.
        case retrying
        /// The upstream recovery owner is handling this tier.
        case upstreamWaiting
        /// A guarded cold reconnect has been committed.
        case restarting
        /// The shared reconnect cooldown or attempt cap deferred recapture.
        case throttled
        /// The current lifecycle or Guard settings cannot admit the repair.
        case unavailable
    }

    /// The canonical tier observed by this snapshot.
    public var tier: DNSResolverTier
    /// An opaque identity of the running resolver selection, if available.
    public var configurationIdentity: String?
    /// The configured resolver source, if it has been observed.
    public var resolverKind: ResolverKind?
    /// The effective transport of the observed tier, if available.
    public var transport: DNSResolverTransport?
    /// The admitted egress of the observed tier, if available.
    public var egress: Egress?
    /// The most recent tier-specific evidence, if a lookup reached this tier.
    public var lastOutcome: Outcome?
    /// Number of tier attempts that supplied failure, reply or service evidence.
    public var attemptCount: Int
    /// Number of lookups served by this tier, including authoritative negatives.
    public var servedCount: Int
    /// Number of replies from this tier that could not serve the lookup.
    public var answeredCount: Int
    /// Number of tier attempts that failed.
    public var failureCount: Int
    /// Number of neutral observations in which this tier was not attempted.
    public var notAttemptedCount: Int
    /// Consecutive failures of this tier, unaffected by other tiers' successes.
    public var consecutiveFailureCount: Int
    /// Consecutive non-serving replies from this tier's current resolver identity.
    public var consecutiveRejectedResponseCount: Int
    /// The time of the latest evidence for this tier.
    public var lastObservedAt: Date?
    /// A bounded outcome label describing the latest tier failure, without endpoint data.
    public var lastFailureReason: String?
    /// The repair appropriate to this tier's source and admitted egress.
    public var recoveryKind: RecoveryKind
    /// The admission or progress of the tier's current repair.
    public var recoveryStatus: RecoveryStatus

    /// Creates a tier snapshot from bounded counters and privacy-safe resolver metadata.
    public init(
        tier: DNSResolverTier,
        configurationIdentity: String? = nil,
        resolverKind: ResolverKind? = nil,
        transport: DNSResolverTransport? = nil,
        egress: Egress? = nil,
        lastOutcome: Outcome? = nil,
        attemptCount: Int = 0,
        servedCount: Int = 0,
        answeredCount: Int = 0,
        failureCount: Int = 0,
        notAttemptedCount: Int = 0,
        consecutiveFailureCount: Int = 0,
        consecutiveRejectedResponseCount: Int = 0,
        lastObservedAt: Date? = nil,
        lastFailureReason: String? = nil,
        recoveryKind: RecoveryKind = .none,
        recoveryStatus: RecoveryStatus = .notNeeded
    ) {
        self.tier = tier
        self.configurationIdentity = configurationIdentity
        self.resolverKind = resolverKind
        self.transport = transport
        self.egress = egress
        self.lastOutcome = lastOutcome
        self.attemptCount = attemptCount
        self.servedCount = servedCount
        self.answeredCount = answeredCount
        self.failureCount = failureCount
        self.notAttemptedCount = notAttemptedCount
        self.consecutiveFailureCount = consecutiveFailureCount
        self.consecutiveRejectedResponseCount = consecutiveRejectedResponseCount
        self.lastObservedAt = lastObservedAt
        self.lastFailureReason = lastFailureReason
        self.recoveryKind = recoveryKind
        self.recoveryStatus = recoveryStatus
    }

    /// Whether a current, deferred Device DNS repair should expose the Guard's explicit reconnect.
    ///
    /// This changes an action, never the whole connection's health. The provider already proved
    /// physical recapture admission before publishing `.throttled`; current settings, connection
    /// and profile permission are rechecked by the host so an old split-tunnel sample cannot
    /// advertise recapture after a resolver or routing change.
    public func permitsManualDeviceDNSRecapture(
        in configuration: AppConfiguration,
        healthUpdatedAt: Date,
        connectedAt: Date?,
        isConnected: Bool,
        guardEnabled: Bool,
        physicalEgressPermitted: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isConnected, guardEnabled, configuration.protectionEnabled,
              physicalEgressPermitted, configurationIdentity?.isEmpty == false,
              resolverKind == .device, transport == .deviceDNS, egress == .physical,
              lastOutcome == .failure, recoveryKind == .recaptureDeviceDNS,
              recoveryStatus == .throttled,
              let connectedAt, let lastObservedAt,
              (0...90).contains(now.timeIntervalSince(healthUpdatedAt)),
              (0...90).contains(now.timeIntervalSince(lastObservedAt)),
              healthUpdatedAt >= connectedAt, lastObservedAt >= connectedAt,
              lastObservedAt <= healthUpdatedAt
        else { return false }
        let selections = configuration.dnsResolutionSelections
        let selectionIndex: Int
        switch tier {
        case .tierZero: return false
        case .tierOne: selectionIndex = 0
        case .tierTwo: selectionIndex = 1
        }
        return selections.indices.contains(selectionIndex)
            && selections[selectionIndex].isEnabled
            && selections[selectionIndex].resolver?.transport == .deviceDNS
    }
}
