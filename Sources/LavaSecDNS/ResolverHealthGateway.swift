import Foundation
import LavaSecKit

/// A response-free completion captured after the provider classifies one smoke probe.
///
/// Raw DNS response bytes remain provider-owned. Construction immediately reduces the
/// supplied results to the bounded evidence required by resolver-health policy.
public struct ResolverHealthSmokeProbeCompletion: Equatable, Sendable {
    fileprivate let evidence: ResolverSmokeProbeEvidence

    /// Creates canonical resolver-health evidence for one completed smoke probe.
    public init(
        occurredAt: Date,
        reason: String,
        primaryResult: DNSResolutionResult,
        primaryAccepted: Bool,
        fallbackResult: DNSResolutionResult?,
        fallbackAccepted: Bool,
        modeInsensitivePrimaryIdentifier: String,
        configuredResolverDisplayName: String
    ) {
        evidence = ResolverSmokeProbeEvidence(
            occurredAt: occurredAt,
            reason: reason,
            primaryResult: primaryResult,
            primaryAccepted: primaryAccepted,
            fallbackResult: fallbackResult,
            fallbackAccepted: fallbackAccepted,
            modeInsensitivePrimaryIdentifier: modeInsensitivePrimaryIdentifier,
            configuredResolverDisplayName: configuredResolverDisplayName
        )
    }
}

/// A response-free completion captured after one organic upstream resolution.
///
/// Construction classifies response quality and serving route once, then retains
/// only bounded resolver-health evidence rather than raw DNS response bytes.
public struct ResolverHealthOrganicUpstreamCompletion: Equatable, Sendable {
    fileprivate let evidence: ResolverOrganicUpstreamEvidence

    /// Creates canonical resolver-health evidence for one organic upstream result.
    public init(occurredAt: Date, result: DNSResolutionResult) {
        evidence = ResolverOrganicUpstreamEvidence(occurredAt: occurredAt, result: result)
    }
}

/// The kind of resolver-runtime reset observed by resolver-health policy.
public enum ResolverHealthGatewayRuntimeResetKind: Equatable, Sendable {
    /// A protection-policy refresh that preserves the active resolver identity.
    case protectionPolicyRefresh
    /// A complete resolver-runtime activation or replacement.
    case fullRuntime(
        currentPrimaryIdentifier: String,
        recordsObservableReset: Bool
    )
}

/// An event accepted by the resolver-health coordinator.
public struct ResolverHealthGatewayEvent: Sendable {
    fileprivate let reducerEvent: ResolverHealthEvent

    private init(reducerEvent: ResolverHealthEvent) {
        self.reducerEvent = reducerEvent
    }

    /// Creates a fresh tunnel-lifecycle event.
    public static func lifecycleReset(occurredAt: Date) -> Self {
        Self(reducerEvent: .lifecycleReset(ResolverHealthLifecycleReset(occurredAt: occurredAt)))
    }

    /// Creates an initial or changed network-path observation.
    public static func networkPathObserved(
        previousKind: TunnelNetworkKind?,
        previousIsSatisfied: Bool?,
        kind: TunnelNetworkKind,
        isSatisfied: Bool,
        observedAt: Date
    ) -> Self {
        Self(
            reducerEvent: .networkPathObserved(
                ResolverNetworkPathObservation(
                    previousKind: previousKind,
                    previousIsSatisfied: previousIsSatisfied,
                    kind: kind,
                    isSatisfied: isSatisfied,
                    observedAt: observedAt
                )
            )
        )
    }

    /// Creates a resolver-configuration boundary event.
    public static func resolverConfigurationChanged(occurredAt: Date) -> Self {
        Self(
            reducerEvent: .resolverConfigurationChanged(
                ResolverConfigurationChangedObservation(occurredAt: occurredAt)
            )
        )
    }

    /// Creates an observation after the provider has reset its resolver runtime.
    public static func resolverRuntimeResetOccurred(
        kind: ResolverHealthGatewayRuntimeResetKind,
        reason: String,
        occurredAt: Date
    ) -> Self {
        let reducerKind: ResolverRuntimeResetObservation.Kind
        switch kind {
        case .protectionPolicyRefresh:
            reducerKind = .protectionPolicyRefresh
        case .fullRuntime(
            let currentPrimaryIdentifier,
            let recordsObservableReset
        ):
            reducerKind = .fullRuntime(
                currentPrimaryIdentifier: currentPrimaryIdentifier,
                recordsObservableReset: recordsObservableReset
            )
        }
        return Self(
            reducerEvent: .resolverRuntimeResetOccurred(
                ResolverRuntimeResetObservation(
                    kind: reducerKind,
                    reason: reason,
                    occurredAt: occurredAt
                )
            )
        )
    }

    /// Creates a failed NetworkExtension settings-reapply observation.
    public static func networkSettingsReapplyFailed(
        reason: String,
        occurredAt: Date
    ) -> Self {
        Self(
            reducerEvent: .networkSettingsReapplyFailed(
                ResolverNetworkSettingsFailureObservation(
                    reason: reason,
                    occurredAt: occurredAt
                )
            )
        )
    }

    static func smokeProbeCompleted(
        _ completion: ResolverHealthSmokeProbeCompletion
    ) -> Self {
        Self(reducerEvent: .smokeProbeCompleted(completion.evidence))
    }

    /// Creates an event from one canonical, response-free organic upstream completion.
    public static func organicUpstreamCompleted(
        _ completion: ResolverHealthOrganicUpstreamCompletion
    ) -> Self {
        Self(reducerEvent: .organicUpstreamCompleted(completion.evidence))
    }
}

extension ResolverHealthGatewayEvent {
    var requiresSmokeProbeToken: Bool {
        if case .smokeProbeCompleted = reducerEvent {
            return true
        }
        return false
    }

    var resetsResolverHealthLifecycle: Bool {
        if case .lifecycleReset = reducerEvent {
            return true
        }
        return false
    }
}

/// A field-wise resolver-health patch that preserves provider-owned snapshot data.
public struct ResolverHealthGatewayProjection: Equatable, Sendable {
    private let projection: ResolverHealthSnapshotProjection

    fileprivate init(projection: ResolverHealthSnapshotProjection) {
        self.projection = projection
    }

    /// Applies only reducer-owned fields to the supplied health snapshot.
    public func apply(to snapshot: inout TunnelHealthSnapshot) {
        projection.apply(to: &snapshot)
    }

    var evidenceState: ResolverHealthEvidenceState {
        projection.state
    }
}

/// Ordered side effects emitted by a resolver-health transition.
public enum ResolverHealthGatewayEffect: Equatable, Sendable {
    /// Marks the projected health snapshot dirty or flushes it immediately.
    case persistHealth(ResolverHealthGatewayPersistenceUrgency)
    /// Evaluates whether a user-facing protection notification is required.
    case evaluateProtectionNotification(at: Date)
    /// Evaluates the QA-only connectivity diagnostic log.
    case evaluateQAConnectivityLog(reason: String, at: Date)
    /// Appends a network activity entry using the current projected health.
    case appendNetworkActivity(NetworkActivityEvent, at: Date)
    /// Ends the coalesced encrypted-fallback logging episode.
    case endEncryptedFallbackLogEpisode(ResolverHealthGatewayFallbackLogEnd)
    /// Cancels any scheduled Device DNS fallback recovery probe.
    case cancelFallbackRecoveryProbe
    /// Cancels any scheduled resolver-wedge recovery probe.
    case cancelWedgeRecoveryProbe
    /// Requests a provider-owned resolver runtime replacement.
    case requestResolverRuntimeReset(ResolverHealthGatewayRuntimeResetRequest)
    /// Delivers SERVFAIL responses collected by the preceding runtime replacement.
    case deliverPendingResolverFailures(reason: String)
    /// Clears a pending Device DNS recapture restart request.
    case clearDeviceDNSRecaptureRestartPending
    /// Signals that the connectivity projection may have changed.
    case signalConnectivityProjectionChanged
    /// Records a durable resolver-health incident.
    case recordIncident(ResolverHealthGatewayIncident)
    /// Appends a privacy-safe resolver-health device-log event.
    case deviceLog(ResolverHealthGatewayDeviceLogEvent)
    /// Reports a completed reconnect-needed episode using its frozen context.
    case reportConnectivityRecovery(ResolverHealthGatewayRecovery)
    /// Credits a productive self-reconnect after confirmed recovery.
    case creditProductiveSelfReconnect(at: Date)
    /// Evaluates whether resolver health warrants a guarded self-reconnect.
    case evaluateSelfReconnect(at: Date)
    /// Schedules the next Device DNS fallback recovery probe when policy permits.
    case scheduleFallbackRecoveryProbe
    /// Schedules the next resolver-wedge recovery probe when policy permits.
    case scheduleWedgeRecoveryProbe
    /// Records one encrypted-fallback-carried organic query for coalesced diagnostics.
    case recordEncryptedFallbackCarry(ResolverHealthGatewayEncryptedFallbackCarry)
}

/// Privacy-safe evidence that the encrypted fallback carried one organic query.
public struct ResolverHealthGatewayEncryptedFallbackCarry: Equatable, Sendable {
    /// The time at which the fallback-carried result completed.
    public let occurredAt: Date
    /// The transport that carried the result.
    public let transport: DNSResolverTransport
    /// The serving resolver endpoint, when one was reported.
    public let resolverAddress: String?
}

/// A durable incident emitted by the resolver-health reducer.
public struct ResolverHealthGatewayIncident: Equatable, Sendable {
    /// The durable incident-ledger category.
    public let kind: IncidentLedgerRecord.Kind
    /// The time at which the incident occurred.
    public let occurredAt: Date
    /// The optional policy reason associated with the incident.
    public let reason: String?
    /// The optional incident duration in milliseconds.
    public let durationMilliseconds: Int?
    /// The optional mechanism that verified recovery.
    public let verifiedBy: String?
}

/// The projected connectivity context frozen when recovery was recognized.
public struct ResolverHealthGatewayActivityContext: Equatable, Sendable {
    /// The connectivity severity at the recovery effect's logical position.
    public let connectivitySeverity: ProtectionConnectivitySeverity
    /// The active network kind at the recovery effect's logical position.
    public let networkKind: TunnelNetworkKind
    /// Whether the active network path was satisfied at that position.
    public let networkPathIsSatisfied: Bool
    /// The resolver transport serving at that position.
    public let resolverTransport: DNSResolverTransport
    /// Whether Device DNS fallback mode was active at that position.
    public let deviceDNSFallbackActive: Bool
}

/// A completed reconnect-needed episode emitted by resolver-health policy.
public struct ResolverHealthGatewayRecovery: Equatable, Sendable {
    /// The beginning of the recovered episode.
    public let startedAt: Date
    /// The time at which recovery was recognized.
    public let recoveredAt: Date
    /// The rounded episode duration in milliseconds.
    public let durationMilliseconds: Int
    /// The policy reason that began the episode.
    public let reason: String
    /// The peak upstream-failure depth observed during the episode.
    public let peakUpstreamFailureCount: Int
    /// The transport that verified recovery.
    public let transport: DNSResolverTransport
    /// The mechanism that verified recovery.
    public let verifiedBy: String
    /// The projected connectivity context at the effect's logical position.
    public let activityContext: ResolverHealthGatewayActivityContext
}

/// A privacy-safe resolver-health event for the provider's device log.
public enum ResolverHealthGatewayDeviceLogEvent: Equatable, Sendable {
    /// A primary resolver smoke probe produced an accepted response.
    case smokeProbeSucceeded(
        reason: String,
        transport: DNSResolverTransport,
        resolverAddress: String?,
        dohHTTPVersion: String?,
        occurredAt: Date
    )
    /// Device DNS produced the accepted smoke response after the primary failed.
    case smokeProbeDeviceFallback(
        reason: String,
        evidenceCount: Int,
        fallbackModeActive: Bool,
        resolverAddress: String?,
        occurredAt: Date
    )
    /// No smoke-probe route produced an accepted response.
    case smokeProbeFailed(
        reason: String,
        failure: String,
        consecutiveSmokeFailures: Int,
        consecutiveRejectedResponses: Int,
        occurredAt: Date
    )
}

/// Persistence urgency requested by a resolver-health transition.
public enum ResolverHealthGatewayPersistenceUrgency: Equatable, Sendable {
    /// Marks health dirty for the normal coalesced persistence cadence.
    case deferred
    /// Forces the current health snapshot to stable storage synchronously.
    case immediate
}

/// A provider-owned resolver-runtime replacement requested by resolver-health policy.
public enum ResolverHealthGatewayRuntimeResetRequest: Equatable, Sendable {
    /// Replaces the full runtime for the supplied reason and force policy.
    case full(reason: String, force: Bool)
}

/// Why the current encrypted-fallback logging episode ended.
public enum ResolverHealthGatewayFallbackLogEnd: Equatable, Sendable {
    /// The serving episode ended through resolver recovery.
    case episodeEnd
    /// A lifecycle, network, or resolver context boundary superseded the episode.
    case contextReset
}

/// The provider-facing result of one resolver-health reduction.
struct ResolverHealthGatewayTransition: Equatable, Sendable {
    /// The field-wise patch for reducer-owned snapshot fields.
    let projection: ResolverHealthGatewayProjection
    /// Side effects to execute in the emitted order after state projection.
    let effects: [ResolverHealthGatewayEffect]
}

/// Internal bridge from reducer-domain transitions to provider-facing values.
enum ResolverHealthGateway {
    static func reduce(
        state: ResolverHealthEvidenceState,
        event: ResolverHealthGatewayEvent,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> (state: ResolverHealthEvidenceState, transition: ResolverHealthGatewayTransition) {
        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: event.reducerEvent,
            projectingOnto: snapshot
        )
        return (
            state: transition.state,
            transition: ResolverHealthGatewayTransition(
                projection: ResolverHealthGatewayProjection(projection: transition.projection),
                effects: transition.effects.map(ResolverHealthGatewayEffect.init)
            )
        )
    }
}

private extension ResolverHealthGatewayEffect {
    init(_ effect: ResolverHealthEffect) {
        switch effect {
        case .persistHealth(let urgency):
            self = .persistHealth(
                urgency == .immediate ? .immediate : .deferred
            )
        case .evaluateProtectionNotification(let occurredAt):
            self = .evaluateProtectionNotification(at: occurredAt)
        case .evaluateQAConnectivityLog(let reason, let occurredAt):
            self = .evaluateQAConnectivityLog(reason: reason, at: occurredAt)
        case .appendNetworkActivity(let event, let occurredAt):
            self = .appendNetworkActivity(event, at: occurredAt)
        case .endEncryptedFallbackLogEpisode(let end):
            self = .endEncryptedFallbackLogEpisode(
                end == .episodeEnd ? .episodeEnd : .contextReset
            )
        case .cancelFallbackRecoveryProbe:
            self = .cancelFallbackRecoveryProbe
        case .cancelWedgeRecoveryProbe:
            self = .cancelWedgeRecoveryProbe
        case .requestResolverRuntimeReset(let request):
            switch request {
            case .full(let reason, let force):
                self = .requestResolverRuntimeReset(.full(reason: reason, force: force))
            }
        case .deliverPendingResolverFailures(let reason):
            self = .deliverPendingResolverFailures(reason: reason)
        case .clearDeviceDNSRecaptureRestartPending:
            self = .clearDeviceDNSRecaptureRestartPending
        case .signalConnectivityProjectionChanged:
            self = .signalConnectivityProjectionChanged
        case .recordIncident(let incident):
            self = .recordIncident(ResolverHealthGatewayIncident(incident))
        case .deviceLog(let event):
            self = .deviceLog(ResolverHealthGatewayDeviceLogEvent(event))
        case .reportConnectivityRecovery(let recovery):
            self = .reportConnectivityRecovery(ResolverHealthGatewayRecovery(recovery))
        case .creditProductiveSelfReconnect(let occurredAt):
            self = .creditProductiveSelfReconnect(at: occurredAt)
        case .evaluateSelfReconnect(let occurredAt):
            self = .evaluateSelfReconnect(at: occurredAt)
        case .scheduleFallbackRecoveryProbe:
            self = .scheduleFallbackRecoveryProbe
        case .scheduleWedgeRecoveryProbe:
            self = .scheduleWedgeRecoveryProbe
        case .recordEncryptedFallbackCarry(let carry):
            self = .recordEncryptedFallbackCarry(
                ResolverHealthGatewayEncryptedFallbackCarry(carry)
            )
        }
    }
}

private extension ResolverHealthGatewayEncryptedFallbackCarry {
    init(_ carry: ResolverEncryptedFallbackCarry) {
        self.init(
            occurredAt: carry.occurredAt,
            transport: carry.transport,
            resolverAddress: carry.resolverAddress
        )
    }
}

private extension ResolverHealthGatewayIncident {
    init(_ incident: ResolverHealthIncident) {
        let kind: IncidentLedgerRecord.Kind
        switch incident.kind {
        case .rejectedResponseStreak:
            kind = .rejectedResponseStreak
        case .wedgeDetected:
            kind = .wedgeDetected
        case .wedgeRecovered:
            kind = .wedgeRecovered
        case .selfReconnectCredited:
            kind = .selfReconnectCredited
        }
        self.init(
            kind: kind,
            occurredAt: incident.occurredAt,
            reason: incident.reason,
            durationMilliseconds: incident.durationMilliseconds,
            verifiedBy: incident.verifiedBy
        )
    }
}

private extension ResolverHealthGatewayActivityContext {
    init(_ context: ResolverHealthActivityContext) {
        self.init(
            connectivitySeverity: context.connectivitySeverity,
            networkKind: context.networkKind,
            networkPathIsSatisfied: context.networkPathIsSatisfied,
            resolverTransport: context.resolverTransport,
            deviceDNSFallbackActive: context.deviceDNSFallbackActive
        )
    }
}

private extension ResolverHealthGatewayRecovery {
    init(_ recovery: ResolverHealthRecovery) {
        self.init(
            startedAt: recovery.startedAt,
            recoveredAt: recovery.recoveredAt,
            durationMilliseconds: recovery.durationMilliseconds,
            reason: recovery.reason,
            peakUpstreamFailureCount: recovery.peakUpstreamFailureCount,
            transport: recovery.transport,
            verifiedBy: recovery.verifiedBy,
            activityContext: ResolverHealthGatewayActivityContext(recovery.activityContext)
        )
    }
}

private extension ResolverHealthGatewayDeviceLogEvent {
    init(_ event: ResolverHealthLogEvent) {
        switch event {
        case .smokeProbeSucceeded(
            let reason,
            let transport,
            let resolverAddress,
            let dohHTTPVersion,
            let occurredAt
        ):
            self = .smokeProbeSucceeded(
                reason: reason,
                transport: transport,
                resolverAddress: resolverAddress,
                dohHTTPVersion: dohHTTPVersion,
                occurredAt: occurredAt
            )
        case .smokeProbeDeviceFallback(
            let reason,
            let evidenceCount,
            let fallbackModeActive,
            let resolverAddress,
            let occurredAt
        ):
            self = .smokeProbeDeviceFallback(
                reason: reason,
                evidenceCount: evidenceCount,
                fallbackModeActive: fallbackModeActive,
                resolverAddress: resolverAddress,
                occurredAt: occurredAt
            )
        case .smokeProbeFailed(
            let reason,
            let failure,
            let consecutiveSmokeFailures,
            let consecutiveRejectedResponses,
            let occurredAt
        ):
            self = .smokeProbeFailed(
                reason: reason,
                failure: failure,
                consecutiveSmokeFailures: consecutiveSmokeFailures,
                consecutiveRejectedResponses: consecutiveRejectedResponses,
                occurredAt: occurredAt
            )
        }
    }
}
