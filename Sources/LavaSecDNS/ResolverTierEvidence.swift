import Foundation
import LavaSecKit

/// One resolver leg's own evidence, sealed before any lower tier can rescue it.
///
/// Lifecycle, latch and path admission belong to the provider. A caller must reject stale
/// evidence before reducing it; completion-time reads cannot establish where a query ran.
public struct ResolverTierEvidence: Equatable, Sendable {
    /// The resolver source vocabulary shared with the privacy-safe health snapshot.
    public typealias ResolverKind = DNSResolverTierHealthSnapshot.ResolverKind
    /// The admitted route vocabulary shared with the health snapshot.
    public typealias Egress = DNSResolverTierHealthSnapshot.Egress
    /// The leg's own outcome, independent of the final client response.
    public typealias Outcome = DNSResolverTierHealthSnapshot.Outcome

    /// Live provider facts required to admit a network-resolver recapture opportunity.
    ///
    /// Route coverage is derived by the provider from the active profile. Keeping that
    /// decision explicit prevents a configured Device tier from granting a repair when its
    /// endpoints actually follow the upstream or physical fallback is forbidden.
    public struct DeviceDNSRecaptureContext: Equatable, Sendable {
        /// The active tunnel lifecycle; zero represents an inactive lifecycle.
        public let lifecycle: UInt64
        /// The current chained latch, or nil in DNS-only execution.
        public let latchEpoch: UInt64?
        /// The latest delivered network-path epoch.
        public let pathEpoch: Int
        /// Whether this live execution context admits the physical resolver rung.
        public let physicalRungPermitted: Bool
        /// Whether the latest delivered network path is usable.
        public let networkPathSatisfied: Bool
        /// Whether filtering is available; a restart cannot rebuild an unavailable artifact.
        public let snapshotAvailable: Bool
        /// Resolver addresses still belonging to the current device DNS capture.
        public let currentDeviceDNSAddresses: [String]
        /// Actual queried addresses covered by the active upstream's routes.
        public let profileCoveredAddresses: [String]

        /// Captures the provider's current route, network and filtering admission facts.
        public init(
            lifecycle: UInt64, latchEpoch: UInt64?, pathEpoch: Int,
            physicalRungPermitted: Bool, networkPathSatisfied: Bool, snapshotAvailable: Bool,
            currentDeviceDNSAddresses: [String], profileCoveredAddresses: [String]
        ) {
            self.lifecycle = lifecycle
            self.latchEpoch = latchEpoch
            self.pathEpoch = pathEpoch
            self.physicalRungPermitted = physicalRungPermitted
            self.networkPathSatisfied = networkPathSatisfied
            self.snapshotAvailable = snapshotAvailable
            self.currentDeviceDNSAddresses = currentDeviceDNSAddresses
            self.profileCoveredAddresses = profileCoveredAddresses
        }
    }

    /// The user's configured tier, preserved when fallback mode promotes its execution.
    public let tier: DNSResolverTier
    /// Whether this resolver follows the upstream, device network or a fixed selection.
    public let resolverKind: ResolverKind
    /// The effective transport of this leg.
    public let transport: DNSResolverTransport
    /// The interface this leg was admitted to use.
    public let egress: Egress
    /// This leg's service, reply, failure or neutral observation.
    public let outcome: Outcome
    /// The lifecycle under which this leg was admitted.
    public let originatingLifecycle: UInt64
    /// The chained data-path latch under which this leg was admitted, if applicable.
    public let originatingLatchEpoch: UInt64?
    /// One epoch for every wire attempt, or a launch epoch for an unstamped fixed endpoint.
    ///
    /// Physical Device DNS never falls back to the launch epoch: any missing or mixed
    /// send-time epoch leaves this nil and cannot authorize recapture.
    public let pathEpoch: Int?
    /// Actual wire endpoints, deduplicated in execution order; never persisted in health.
    public let resolverAddresses: [String]
    /// Number of wire attempts represented by this leg.
    public let attemptCount: Int
    /// The latest transport outcome explaining its failure, if any.
    public let failureReason: ResolverAttemptOutcome?
    /// A non-serving reply, excluding a well-formed truncated reply that proves liveness.
    public let isResolverRejection: Bool
    /// Earliest actual send in this leg, present only when every wire attempt is stamped.
    /// UDP/TCP retries of one leg cannot become independent failure confirmations.
    public let sendSequence: UInt64?
    /// Raw reply observation order, retained while a slower lower tier finishes.
    public private(set) var replySequence: UInt64?

    /// Creates already-classified evidence for a leg whose execution identity is known.
    public init(
        tier: DNSResolverTier, resolverKind: ResolverKind, transport: DNSResolverTransport,
        egress: Egress, outcome: Outcome, originatingLifecycle: UInt64,
        originatingLatchEpoch: UInt64?, pathEpoch: Int?, resolverAddresses: [String],
        attemptCount: Int, failureReason: ResolverAttemptOutcome? = nil,
        isResolverRejection: Bool = false, sendSequence: UInt64? = nil,
        replySequence: UInt64? = nil
    ) {
        self.tier = tier
        self.resolverKind = resolverKind
        self.transport = transport
        self.egress = egress
        self.outcome = outcome
        self.originatingLifecycle = originatingLifecycle
        self.originatingLatchEpoch = originatingLatchEpoch
        self.pathEpoch = pathEpoch
        self.resolverAddresses = resolverAddresses
        self.attemptCount = max(0, attemptCount)
        self.failureReason = failureReason
        self.isResolverRejection = isResolverRejection
        self.sendSequence = sendSequence
        self.replySequence = replySequence
    }

    /// Classifies a raw leg before another leg's attempts or response are merged into it.
    public init(
        tier: DNSResolverTier, resolverKind: ResolverKind, egress: Egress,
        result: DNSResolutionResult, originatingLifecycle: UInt64,
        originatingLatchEpoch: UInt64?, observationPathEpoch: Int? = nil
    ) {
        let wireAttempts = result.attempts.filter { $0.outcome.reachedTheWire }
        let abandoned = result.attempts.contains { $0.outcome.endsTheResolutionLadder }
        let replied = wireAttempts.contains {
            $0.outcome == .success || $0.outcome == .truncatedAnswer || $0.outcome == .mismatchedResponse
        }
        let served = DNSResolverSmokeProbe.indicatesServedAnswer(result.response)
        let rejection = result.response.map { _ in
            DNSResolverSmokeProbe.indicatesResolverFailure(result.response)
        } ?? wireAttempts.contains { $0.outcome == .mismatchedResponse }
        let outcome: Outcome
        if abandoned || wireAttempts.isEmpty {
            outcome = .notAttempted
        } else if served {
            outcome = .served
        } else if replied || result.response != nil {
            outcome = .answered
        } else {
            outcome = .failure
        }

        let wireEpochs = wireAttempts.compactMap(\.pathEpoch)
        let wireSequences = wireAttempts.compactMap(\.sendSequence)
        let sendSequence = !wireAttempts.isEmpty && wireSequences.count == wireAttempts.count
            && wireSequences.allSatisfy({ $0 > 0 }) ? wireSequences.min() : nil
        let replySequence = wireAttempts.compactMap(\.replySequence).max()
        let actualEgresses = wireAttempts.compactMap(\.actualEgress)
        let resolvedEgress: Egress
        if actualEgresses.isEmpty {
            resolvedEgress = egress
        } else if actualEgresses.count == wireAttempts.count,
            let first = actualEgresses.first, actualEgresses.allSatisfy({ $0 == first }) {
            resolvedEgress = first
        } else {
            resolvedEgress = .mixed
        }
        let strictEpoch = wireEpochs.count == wireAttempts.count
            && Set(wireEpochs).count == 1 ? wireEpochs.first : nil
        let pathEpoch: Int?
        if resolverKind == .device, resolvedEgress == .physical {
            pathEpoch = strictEpoch
        } else if !wireEpochs.isEmpty {
            pathEpoch = strictEpoch
        } else {
            pathEpoch = observationPathEpoch
        }
        var addresses: [String] = []
        for attempt in wireAttempts where !addresses.contains(attempt.address) {
            addresses.append(attempt.address)
        }
        self.init(
            tier: tier, resolverKind: resolverKind, transport: result.transport,
            egress: resolvedEgress, outcome: outcome, originatingLifecycle: originatingLifecycle,
            originatingLatchEpoch: originatingLatchEpoch, pathEpoch: pathEpoch,
            resolverAddresses: addresses, attemptCount: wireAttempts.count,
            failureReason: wireAttempts.last(where: { $0.outcome != .success })?.outcome,
            isResolverRejection: outcome == .answered && rejection,
            sendSequence: sendSequence, replySequence: replySequence)
    }

    /// Whether this evidence belongs to the provider's current execution context.
    public func isCurrent(lifecycle: UInt64, latchEpoch: UInt64?, pathEpoch: Int) -> Bool {
        originatingLifecycle != 0 && originatingLifecycle == lifecycle
            && originatingLatchEpoch == latchEpoch && self.pathEpoch == pathEpoch
    }

    /// Retains the provider's raw-reply order before any slower fallback is merged.
    public func recordingReply(observationSequence: UInt64) -> Self {
        guard outcome == .served || outcome == .answered else { return self }
        var copy = self
        copy.replySequence = observationSequence
        return copy
    }

    /// Retains a completed attempt after client expiry without crediting delivered service.
    ///
    /// A late valid response proves this tier replied, but cannot count as a client rescue
    /// or productive recapture (INV-DNS-6). Actual failures and neutral outcomes stay intact.
    // pinned: ResolverTierEvidenceTests.testLateAnswerProvesAReplyWithoutClaimingDeliveredService
    public func recordingClientDeadlineExpired() -> Self {
        guard outcome == .served else { return self }
        return Self(
            tier: tier, resolverKind: resolverKind, transport: transport, egress: egress,
            outcome: .answered, originatingLifecycle: originatingLifecycle,
            originatingLatchEpoch: originatingLatchEpoch, pathEpoch: pathEpoch,
            resolverAddresses: resolverAddresses, attemptCount: attemptCount,
            failureReason: nil, isResolverRejection: false, sendSequence: sendSequence,
            replySequence: replySequence)
    }

    /// Whether this actual Device DNS failure can justify considering a cold recapture.
    ///
    /// Guard intent, on-demand confirmation and the shared restart budget are separate
    /// admission facts checked immediately before teardown by `TunnelSelfReconnectPolicy`.
    public func permitsDeviceDNSRecapture(in context: DeviceDNSRecaptureContext) -> Bool {
        switch tier {
        case .tierZero: return false
        case .tierOne, .tierTwo: break
        }
        guard resolverKind == .device, transport == .deviceDNS, egress == .physical,
            outcome == .failure, attemptCount > 0,
            context.physicalRungPermitted, context.networkPathSatisfied, context.snapshotAvailable,
            isCurrent(lifecycle: context.lifecycle, latchEpoch: context.latchEpoch, pathEpoch: context.pathEpoch),
            !resolverAddresses.isEmpty
        else { return false }
        let captured = Set(context.currentDeviceDNSAddresses)
        let covered = Set(context.profileCoveredAddresses)
        return resolverAddresses.allSatisfy { captured.contains($0) && !covered.contains($0) }
    }
}

/// Independent, bounded health for the three canonical resolver tiers.
///
/// Only service from the same configured tier clears its failure evidence. This prevents a
/// working upstream or fixed fallback from hiding a failed network-provided resolver.
public struct ResolverTierHealth: Equatable, Sendable {
    /// The repair opportunity a resolver's source supports; admission stays with the provider.
    public typealias RecoveryAction = DNSResolverTierHealthSnapshot.RecoveryKind
    /// Privacy-safe state suitable for the shared tunnel health snapshot.
    public typealias State = DNSResolverTierHealthSnapshot
    private var states: [State] = DNSResolverTier.allCases.map { State(tier: $0) }
    private struct DeviceConfirmation: Equatable, Sendable {
        var lastReplySequence: UInt64?
        var hasUnorderedReply = false
        var firstFailureSendSequence: UInt64?
        var firstFailureCompletionSequence: UInt64?
        var confirmedSendSequence: UInt64?
        var confirmedCompletionSequence: UInt64?

        mutating func clearFailures() {
            firstFailureSendSequence = nil
            firstFailureCompletionSequence = nil
            confirmedSendSequence = nil
            confirmedCompletionSequence = nil
        }
    }
    private var deviceConfirmations = DNSResolverTier.allCases.map { _ in DeviceConfirmation() }

    /// Creates empty state for all three tiers.
    public init() {}

    /// All tier states in canonical order, with no endpoint addresses or queried names.
    public var snapshots: [State] { states }

    /// Current state for one configured tier.
    public func state(for tier: DNSResolverTier) -> State {
        states[index(for: tier)]
    }

    /// Records provider admission or progress without changing resolver evidence.
    public mutating func setRecoveryStatus(_ status: State.RecoveryStatus, for tier: DNSResolverTier) {
        states[index(for: tier)].recoveryStatus = status
    }

    /// Whether a real first failure awaits a separately launched Device DNS wire attempt.
    public func deviceDNSConfirmationNeeded(for tier: DNSResolverTier) -> Bool {
        let confirmation = deviceConfirmations[index(for: tier)]
        return confirmation.firstFailureCompletionSequence != nil
            && confirmation.confirmedCompletionSequence == nil
    }

    /// Whether two independent failures still authorize considering this tier's recapture.
    public func deviceDNSRecaptureIsConfirmed(for tier: DNSResolverTier) -> Bool {
        deviceConfirmations[index(for: tier)].confirmedCompletionSequence != nil
    }

    /// The current independent confirmation's completion identity, if still valid.
    public func deviceDNSRecaptureObservationSequence(for tier: DNSResolverTier) -> UInt64? {
        deviceConfirmations[index(for: tier)].confirmedCompletionSequence
    }

    /// Checks the exact confirmation captured by a deferred teardown grant.
    public func deviceDNSRecaptureIsConfirmed(
        for tier: DNSResolverTier, sendSequence: UInt64, observationSequence: UInt64
    ) -> Bool {
        let confirmation = deviceConfirmations[index(for: tier)]
        return confirmation.confirmedSendSequence == sendSequence
            && confirmation.confirmedCompletionSequence == observationSequence
    }

    /// Requires a fresh independent attempt after a cooldown wake, preserving counters.
    public mutating func invalidateDeviceDNSConfirmation(
        for tier: DNSResolverTier, observationSequence: UInt64? = nil
    ) {
        let index = index(for: tier)
        let previousConfirmation = deviceConfirmations[index].confirmedCompletionSequence
        if let firstFailure = deviceConfirmations[index].firstFailureCompletionSequence {
            // A forced recheck fences old work already in flight at wake. Without a wake
            // stamp, at least require a send after the preceding confirmation completed.
            deviceConfirmations[index].firstFailureCompletionSequence =
                max(firstFailure, observationSequence ?? previousConfirmation ?? firstFailure)
        }
        deviceConfirmations[index].confirmedSendSequence = nil
        deviceConfirmations[index].confirmedCompletionSequence = nil
        if deviceDNSConfirmationNeeded(for: tier) {
            states[index].recoveryKind = .recaptureDeviceDNS
            states[index].recoveryStatus = .waiting
        }
    }

    /// Fences a raw Device reply before a slower fallback or merged completion finishes.
    /// Provider-owned lifecycle, path, tier and configuration validation precedes this call.
    public mutating func observeDeviceDNSReply(for tier: DNSResolverTier, observationSequence: UInt64?) {
        let index = index(for: tier)
        var confirmation = deviceConfirmations[index]
        guard let sequence = observationSequence, sequence > 0 else {
            confirmation.clearFailures()
            confirmation.lastReplySequence = nil
            confirmation.hasUnorderedReply = true
            deviceConfirmations[index] = confirmation
            states[index].recoveryKind = .none
            states[index].recoveryStatus = .notNeeded
            return
        }
        guard confirmation.lastReplySequence.map({ sequence > $0 }) ?? true else { return }
        confirmation.lastReplySequence = sequence
        confirmation.hasUnorderedReply = false
        if confirmation.firstFailureSendSequence.map({ sequence > $0 }) ?? true {
            confirmation.clearFailures()
            states[index].recoveryKind = .none
            states[index].recoveryStatus = .notNeeded
        }
        deviceConfirmations[index] = confirmation
    }

    /// Reduces current evidence and returns its immediate repair opportunity.
    ///
    /// The provider rejects obsolete lifecycle, latch, path and address identities before
    /// calling this method. A repair opportunity never bypasses routing or restart admission.
    @discardableResult
    public mutating func apply(
        _ evidence: ResolverTierEvidence, at now: Date = Date(), observationSequence: UInt64? = nil
    ) -> RecoveryAction {
        let index = index(for: evidence.tier)
        var state = states[index]
        let previousState = state
        // Backoff and local refusals supply no newer resolver verdict. Preserve the last
        // actual observation and its repair so the retry wait cannot hide a failed tier.
        // pinned: ResolverTierEvidenceTests.testNeutralBackoffPreservesTheLastActualFailureAndDeferredRepair
        if evidence.outcome == .notAttempted,
            let previous = state.lastOutcome, previous != .notAttempted {
            increment(&state.notAttemptedCount)
            states[index] = state
            return .none
        }
        state.resolverKind = evidence.resolverKind
        state.transport = evidence.transport
        state.egress = evidence.egress
        state.lastOutcome = evidence.outcome
        state.lastObservedAt = now
        let action: RecoveryAction
        switch evidence.outcome {
        case .served:
            if evidence.resolverKind == .device {
                observeDeviceDNSReply(for: evidence.tier, observationSequence: evidence.replySequence ?? observationSequence)
            }
            add(evidence.attemptCount, to: &state.attemptCount)
            increment(&state.servedCount)
            state.consecutiveFailureCount = 0
            state.consecutiveRejectedResponseCount = 0
            state.lastFailureReason = nil
            state.recoveryKind = .none
            state.recoveryStatus = .notNeeded
            action = .none
        case .failure:
            add(evidence.attemptCount, to: &state.attemptCount)
            increment(&state.failureCount)
            increment(&state.consecutiveFailureCount)
            state.consecutiveRejectedResponseCount = 0
            state.lastFailureReason = evidence.failureReason?.rawValue ?? "no-response"
            if evidence.resolverKind == .device, evidence.egress == .physical {
                action = recordDeviceFailure(evidence, observationSequence: observationSequence)
                let pending = deviceDNSConfirmationNeeded(for: evidence.tier)
                let confirmed = deviceDNSRecaptureIsConfirmed(for: evidence.tier)
                state.recoveryKind = pending || confirmed ? .recaptureDeviceDNS : .none
                state.recoveryStatus = confirmed ? .eligible : pending ? .waiting : .unavailable
            } else {
                action = repair(for: evidence)
                state.recoveryKind = action
                state.recoveryStatus = status(for: action)
            }
        case .answered:
            if evidence.resolverKind == .device {
                observeDeviceDNSReply(for: evidence.tier, observationSequence: evidence.replySequence ?? observationSequence)
            }
            add(evidence.attemptCount, to: &state.attemptCount)
            increment(&state.answeredCount)
            // This resolver responded, so a previous silence no longer licenses a cold
            // recapture. An error reply still does not establish service for the name.
            state.consecutiveFailureCount = 0
            if evidence.isResolverRejection {
                increment(&state.consecutiveRejectedResponseCount)
                state.lastFailureReason = evidence.failureReason?.rawValue ?? "resolver-rejected-response"
                switch evidence.resolverKind {
                case .upstream: action = .upstreamSession
                case .fixed: action = .retryFixedEndpoint
                case .device: action = .none
                }
            } else {
                state.consecutiveRejectedResponseCount = 0
                state.lastFailureReason = nil
                action = .none
            }
            state.recoveryKind = action
            state.recoveryStatus = evidence.isResolverRejection && evidence.resolverKind == .device
                ? .waiting : status(for: action)
        case .notAttempted:
            increment(&state.notAttemptedCount)
            action = .none
        }
        if evidence.resolverKind == .device,
            evidence.outcome == .served || evidence.outcome == .answered,
            deviceDNSConfirmationNeeded(for: evidence.tier) || deviceDNSRecaptureIsConfirmed(for: evidence.tier) {
            // A replay of an older raw reply may arrive after its already-observed fence.
            // Its counters remain useful, but it cannot retire a newer independent failure.
            state.resolverKind = previousState.resolverKind
            state.transport = previousState.transport
            state.egress = previousState.egress
            state.lastOutcome = previousState.lastOutcome
            state.lastObservedAt = previousState.lastObservedAt
            state.lastFailureReason = previousState.lastFailureReason
            state.consecutiveFailureCount = previousState.consecutiveFailureCount
            state.consecutiveRejectedResponseCount = previousState.consecutiveRejectedResponseCount
            state.recoveryKind = previousState.recoveryKind
            state.recoveryStatus = previousState.recoveryStatus
        }
        states[index] = state
        return action
    }

    // Sequence order makes concurrent client failures and UDP/TCP retries distinct from
    // a new attempt sent after a completed failure. Wall-clock changes cannot grant repair.
    // pinned: ResolverTierEvidenceTests.testParallelFailureBurstCannotConfirmDeviceRecapture
    private mutating func recordDeviceFailure(
        _ evidence: ResolverTierEvidence, observationSequence: UInt64?
    ) -> RecoveryAction {
        guard evidence.tier != .tierZero, evidence.transport == .deviceDNS,
              evidence.attemptCount > 0,
              let send = evidence.sendSequence, send > 0,
              let completion = observationSequence, completion > send else { return .none }
        let index = index(for: evidence.tier)
        var confirmation = deviceConfirmations[index]
        guard !confirmation.hasUnorderedReply,
              confirmation.lastReplySequence.map({ send > $0 }) ?? true else { return .none }
        if let firstCompletion = confirmation.firstFailureCompletionSequence {
            guard send > firstCompletion else { return .none }
            confirmation.confirmedSendSequence = send
            confirmation.confirmedCompletionSequence = completion
            deviceConfirmations[index] = confirmation
            return .recaptureDeviceDNS
        }
        confirmation.firstFailureSendSequence = send
        confirmation.firstFailureCompletionSequence = completion
        deviceConfirmations[index] = confirmation
        return .none
    }

    private func index(for tier: DNSResolverTier) -> Int {
        switch tier {
        case .tierZero: return 0
        case .tierOne: return 1
        case .tierTwo: return 2
        }
    }

    private func repair(for evidence: ResolverTierEvidence) -> RecoveryAction {
        switch evidence.resolverKind {
        case .upstream: return .upstreamSession
        case .fixed: return .retryFixedEndpoint
        case .device: return evidence.egress == .physical ? .recaptureDeviceDNS : .none
        }
    }

    private func status(for action: RecoveryAction) -> State.RecoveryStatus {
        switch action {
        case .upstreamSession: return .upstreamWaiting
        case .retryFixedEndpoint: return .retrying
        case .recaptureDeviceDNS: return .eligible
        case .none: return .notNeeded
        }
    }

    private func increment(_ value: inout Int) {
        if value < Int.max { value += 1 }
    }

    private func add(_ amount: Int, to value: inout Int) {
        value = value > Int.max - amount ? Int.max : value + amount
    }
}
