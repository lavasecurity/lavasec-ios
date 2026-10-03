import Foundation

/// Current provider health, separate from the setup/forwarding milestones it has witnessed.
public enum ChainedRuntimeCondition: String, Codable, Equatable, Sendable {
    case normal, suspended, recovering, offline, retired
}

/// The packet-tunnel runtime's authoritative description of the protection path that is live now.
///
/// This deliberately has no app preference input. A saved preference describes what the next
/// tunnel should build; only this observation can describe the tunnel process that is already
/// running. Keeping the distinction in the type system prevents a settings toggle from relabeling
/// a still-live chained session as DNS-only.
public enum ChainedRuntimeObservation: Equatable, Sendable {
    /// Identity and cumulative forwarding evidence for one live chained session runner.
    public struct Session: Equatable, Sendable {
        /// The runner generation. It changes whenever the provider replaces the session runner.
        public let generation: UInt64

        /// The channel incarnation within that runner; forwarding counters reset on rebind.
        public let transportGeneration: UInt64

        /// Cumulative non-DNS bytes forwarded back through this runner.
        public let forwardedBytes: UInt64

        /// A fresh current-provider setup observation, distinct from forwarding proof.
        public let setupReady: Bool
        public let providerLifecycleID: String?
        public let verificationEpoch: UInt64?
        public let forwardingBaseline: UInt64
        public let runtimeCondition: ChainedRuntimeCondition
        public let health: TunnelHealthSnapshot?
        public let healthSampledAt: Date?

        /// Creates one authoritative session sample.
        public init(generation: UInt64, forwardedBytes: UInt64, transportGeneration: UInt64 = 0,
                    setupReady: Bool = false, providerLifecycleID: String? = nil,
                    verificationEpoch: UInt64? = nil, forwardingBaseline: UInt64 = 0,
                    runtimeCondition: ChainedRuntimeCondition = .normal,
                    health: TunnelHealthSnapshot? = nil, healthSampledAt: Date = Date()) {
            self.generation = generation
            self.forwardedBytes = forwardedBytes
            self.transportGeneration = transportGeneration
            self.setupReady = setupReady
            self.providerLifecycleID = providerLifecycleID
            self.verificationEpoch = verificationEpoch
            self.forwardingBaseline = forwardingBaseline
            self.runtimeCondition = runtimeCondition
            self.health = health
            self.healthSampledAt = health == nil ? nil : healthSampledAt
        }
    }

    /// The provider lifecycle is not active, so no protection claim can be inferred from it.
    case inactive

    /// The live tunnel is intentionally DNS-only and has no chained runner to prove.
    case dnsOnly

    /// The live tunnel is chained. A missing session means the runner is absent right now, not
    /// that the tunnel silently became DNS-only.
    case chained(session: Session?)
}

/// Pure state machine for the app-side chained-connect claim, observation loop, on-demand arm,
/// and reducer-owned vanish notice.
///
/// The caller supplies lifecycle changes, runtime observations, and async arm completions. The
/// reducer mutates only ``State`` and returns ordered ``Effect`` values; it never writes a shared
/// banner or starts work itself. That separation makes message ownership and every suspension race
/// deterministic in unit tests.
public enum ChainedConnectLifecyclePolicy {
    /// Grace period for retaining a witnessed milestone while an observation reply is unavailable.
    public static let observationGraceSeconds: TimeInterval = 3

    /// Maximum age of accepted evidence before a missing observation becomes Checking.
    public static let maximumEvidenceAgeSeconds: TimeInterval = 10

    public enum Milestone: String, Equatable, Sendable {
        case none, setupVerified, forwardingVerified
    }

    public enum SuccessFeedbackDisposition: Equatable, Sendable {
        case deliver, consumeSilently, retryOnFreshEvidence
    }

    /// Revalidates the accepted outcome after any asynchronous mutation fence.
    public static func successFeedbackDisposition(state: State, acceptedGeneration: UInt64,
        currentGeneration: UInt64, isActive: Bool, hasError: Bool,
        status: ProtectionStatus, now: TimeInterval) -> SuccessFeedbackDisposition {
        guard isActive, acceptedGeneration == currentGeneration else { return .consumeSilently }
        guard !hasError, state.canDeliverSuccess(now: now) else { return .retryOnFreshEvidence }
        // Audible/haptic success must agree with the Guard panel's affirmed state.
        // Verified setup and working fallback still have pending/attention semantics.
        return GuardStatusPresentation(status: status).materialIntent == .affirmed
            ? .deliver : .retryOnFreshEvidence
    }

    /// One publication for all Guard readers; a render cannot see a partially updated claim.
    public struct Projection: Equatable, Sendable {
        public let claim: Claim
        public let setupReady: Bool
        public let notice: Notice
        public let runtimeCondition: ChainedRuntimeCondition
        public let connectivity: ProtectionConnectivitySeverity?
        public let ownsHealth: Bool
        /// Once this projection owns health, missing live evidence stays unavailable.
        /// A persisted DNS assessment cannot revive an expired chained observation.
        public func effectiveConnectivity(fallback: ProtectionConnectivitySeverity) -> ProtectionConnectivitySeverity? {
            ownsHealth ? connectivity : fallback
        }
        public init(claim: Claim = .inactive, setupReady: Bool = false, notice: Notice = .none,
                    runtimeCondition: ChainedRuntimeCondition = .normal,
                    connectivity: ProtectionConnectivitySeverity? = nil, ownsHealth: Bool = false) {
            self.claim = claim
            self.setupReady = setupReady
            self.notice = notice
            self.runtimeCondition = runtimeCondition
            self.connectivity = connectivity
            self.ownsHealth = ownsHealth
        }
    }
    /// How long a connected epoch may wait for forwarding evidence before its initial claim becomes
    /// unconfirmed. Sampling continues after this window, so later traffic can still promote it.
    public static let establishmentTimeoutSeconds =
        ChainedEstablishmentPolicy.defaultTimeoutSeconds

    /// The protection claim derived from the outer lifecycle and authoritative runtime evidence.
    public enum Claim: Equatable, Sendable {
        /// There is no currently connected app epoch.
        case inactive

        /// The epoch is connected but its live path has not yet proved forwarding.
        case establishing

        /// A previously proved runner could not be sampled. No current success is claimed.
        case checking

        /// The evidence window ended without proof. The tunnel remains alive and monitored.
        case unconfirmed

        /// DNS-only is live, or a chained session has produced fresh forwarding evidence.
        case confirmed
    }

    /// A notice lane owned exclusively by this reducer.
    ///
    /// Keeping this separate from a shared app message means neither gate startup nor late
    /// promotion can erase an unrelated, newer error. The connection identity prevents an async
    /// arm completion from publishing or clearing another epoch's notice.
    public enum Notice: Equatable, Sendable {
        /// This reducer owns no visible or deferred notice.
        case none

        /// An unconfirmed connection vanished while its on-demand arm result was still pending.
        case pending(connection: UInt64)

        /// The connection vanished and no confirmed on-demand recovery will bring it back.
        case visible(connection: UInt64)
    }

    /// Complete reducer state. Callers publish ``claim`` and ``notice``; the remaining fields are
    /// reducer bookkeeping and intentionally have no public setters.
    public struct State: Equatable, Sendable {
        /// The current protection claim.
        public fileprivate(set) var claim: Claim

        /// Verified setup on the current initial transport, without a forwarding claim.
        public fileprivate(set) var setupReady = false
        public fileprivate(set) var milestone: Milestone = .none
        public fileprivate(set) var lastAcceptedAt: TimeInterval?
        public fileprivate(set) var gapStartedAt: TimeInterval?
        public fileprivate(set) var runtimeCondition: ChainedRuntimeCondition = .normal
        fileprivate var connectivity: ProtectionConnectivitySeverity?
        fileprivate var ownsHealth = false
        fileprivate var continuitySupported = false
        public var graceDeadline: TimeInterval? {
            guard let gapStartedAt, let lastAcceptedAt, continuitySupported else { return nil }
            return min(gapStartedAt + observationGraceSeconds, lastAcceptedAt + maximumEvidenceAgeSeconds)
        }
        public var projection: Projection {
            .init(claim: claim, setupReady: setupReady, notice: notice, runtimeCondition: runtimeCondition,
                  connectivity: connectivity, ownsHealth: ownsHealth)
        }
        /// Prefetch is only an optimization for a previously resolved, continuously identified
        /// connection. A pending explicit-start acknowledgement stays on its existing active lane.
        public var foregroundEntryIdentity: ChainedForegroundEntryPrefetch.Identity? {
            guard status == .connected, samplingRequired, !teardownActive,
                  milestone != .none, initialResolutionDone,
                  !initialResolutionWasUserInitiated || successFeedbackResolved,
                  let evidence else { return nil }
            return .init(providerLifecycleID: evidence.providerLifecycleID,
                         sessionGeneration: evidence.generation,
                         transportGeneration: evidence.transportGeneration,
                         verificationEpoch: evidence.verificationEpoch)
        }
        /// Current connected epoch available to a fresh saved-profile recovery request, including
        /// DNS-only epochs whose runtime sampler has already stopped.
        public var onDemandRepairConnection: UInt64? {
            status == .connected && !teardownActive ? connection : nil
        }
        public func canDeliverSuccess(now: TimeInterval) -> Bool {
            guard gapStartedAt == nil, runtimeCondition == .normal, let lastAcceptedAt,
                  now >= lastAcceptedAt, now - lastAcceptedAt < maximumEvidenceAgeSeconds else { return false }
            return claim == .confirmed || setupReady
        }

        /// The current reducer-owned vanish notice.
        public fileprivate(set) var notice: Notice

        fileprivate(set) var status: ProtectionLifecycleStatus
        fileprivate(set) var connection: UInt64?
        fileprivate(set) var samplingConnection: UInt64?
        fileprivate var samplingRequired: Bool
        fileprivate var establishmentStartedAt: TimeInterval?
        fileprivate var evidence: SessionEvidence?
        fileprivate var setupEvidenceInvalidated = false
        fileprivate var initialResolutionDone: Bool
        fileprivate var initialResolutionWasUserInitiated: Bool
        fileprivate var successFeedbackResolved: Bool
        fileprivate var successFeedbackPending: Bool
        fileprivate var teardownActive: Bool
        fileprivate var onDemandConfirmed: Bool
        fileprivate var pendingArm: PendingArm?
        fileprivate var armAttemptedConnection: UInt64?
        fileprivate var droppedUnconfirmedConnection: UInt64?
        fileprivate var nextConnectionID: UInt64
        fileprivate var nextArmID: UInt64

        /// Creates an inactive reducer with no connection, evidence, arm, or owned notice.
        public init() {
            claim = .inactive
            notice = .none
            status = .invalid
            connection = nil
            samplingConnection = nil
            samplingRequired = false
            establishmentStartedAt = nil
            evidence = nil
            initialResolutionDone = false
            initialResolutionWasUserInitiated = false
            successFeedbackResolved = false
            successFeedbackPending = false
            teardownActive = false
            onDemandConfirmed = false
            pendingArm = nil
            armAttemptedConnection = nil
            droppedUnconfirmedConnection = nil
            nextConnectionID = 1
            nextArmID = 1
        }
    }

    /// A deterministic input to the reducer.
    public enum Event: Equatable, Sendable {
        /// Supplies the latest outer protection lifecycle. A fresh edge into `.connected` creates a
        /// new app connection identity and starts runtime sampling regardless of saved mode.
        case statusChanged(
            ProtectionLifecycleStatus,
            onDemandConfirmed: Bool,
            userInitiated: Bool,
            now: TimeInterval
        )

        /// Supplies one runtime observation for a particular app connection. `nil` is an IPC miss
        /// and therefore conservative; it is never interpreted as DNS-only.
        case observed(
            connection: UInt64,
            observation: ChainedRuntimeObservation?,
            now: TimeInterval
        )

        /// Completes an on-demand arm attempt. Only the exact live token may affect its connection's
        /// notice; every completion still requests a live protection-status reconciliation.
        case onDemandArmFinished(id: UInt64, confirmed: Bool)

        /// Requests one recovery-rule repair after a fresh foreground manager/intent read. A
        /// missing generation capture requires a new observation epoch; an existing valid capture
        /// stays unchanged so a newer external restart cannot be adopted by an old descendant.
        case onDemandRepairRequested(connection: UInt64, startsNewObservation: Bool, now: TimeInterval)

        /// A success attempt either delivered/was superseded, or met a temporary
        /// missing claim after waiting for the mutation fence. Only the latter
        /// leaves the explicit start eligible on its next confirmed observation.
        case successFeedbackFinished(connection: UInt64, retryWhenConfirmed: Bool)

        /// Starts or ends a fallible teardown suspension. Suspension pauses sampling without
        /// erasing the claim or evidence, so a failed teardown resumes conservatively.
        case teardownChanged(isActive: Bool)

        /// Visibility changes cancel query tokens, but are not negative tunnel evidence.
        case observationSuspended(now: TimeInterval)
        case observationResumed(now: TimeInterval)
        /// The app schedules this absolute deadline independently of an in-flight IPC query.
        case observationDeadline(connection: UInt64, deadline: TimeInterval, now: TimeInterval)
    }

    /// Work the caller performs after a reduction, in the order returned.
    public enum Effect: Equatable, Sendable {
        /// Stop the current runtime observation loop, if any.
        case stopSampling

        /// Start runtime observations scoped to this app connection identity.
        case startSampling(connection: UInt64)

        /// Best-effort arm Connect-On-Demand with a completion token owned by this reducer.
        case ensureOnDemand(id: UInt64, connection: UInt64)

        /// Publish the one-shot result of the initial evidence window.
        ///
        /// Initial confirmation may drive user-initiated success feedback. A timed-out attempt
        /// retains its one success opportunity through ``resolveDeferredSuccess``.
        /// `receivedByteDelta` describes the observation that resolved the window;
        /// it is nil when that poll had no runner evidence, even if an older poll did.
        case resolveInitialClaim(
            connection: UInt64,
            confirmed: Bool,
            userInitiated: Bool,
            receivedByteDelta: UInt64?
        )

        /// The same explicit start acquired proof after its initial timeout or a
        /// deferred delivery. At most one attempt is outstanding; completion owns
        /// whether another attempt is needed. Non-user starts stay silent.
        case resolveDeferredSuccess(connection: UInt64, receivedByteDelta: UInt64?)

        /// Completes setup for this explicit start using the same one-shot success ownership.
        case resolveSetupReady(connection: UInt64, userInitiated: Bool)

        /// Refresh the outer protection lifecycle after any arm completion, including a stale one.
        case reconcileProtectionStatus
    }

    /// Reduces one event into state and ordered caller work.
    ///
    /// - Parameters:
    ///   - state: State mutated synchronously by this event.
    ///   - event: Lifecycle, observation, arm-completion, or teardown input.
    /// - Returns: Ordered effects for the caller. Repeating an already-consumed state input does not
    ///   duplicate effects, except that every arm completion requests reconciliation by contract.
    @discardableResult
    public static func reduce(state: inout State, event: Event) -> [Effect] {
        switch event {
        case let .statusChanged(status, onDemandConfirmed, userInitiated, now):
            return reduceStatus(
                state: &state,
                status: status,
                onDemandConfirmed: onDemandConfirmed,
                userInitiated: userInitiated,
                now: now)
        case let .observed(connection, observation, now):
            return reduceObservation(
                state: &state,
                connection: connection,
                observation: observation,
                now: now)
        case let .onDemandArmFinished(id, confirmed):
            return reduceArmCompletion(state: &state, id: id, confirmed: confirmed)
        case let .onDemandRepairRequested(connection, startsNewObservation, now):
            guard state.status == .connected, state.connection == connection,
                  !state.teardownActive, !state.onDemandConfirmed
            else { return [] }
            if startsNewObservation {
                // Fresh saved-manager/intent admission may replace an epoch whose unusable
                // generation capture still owns a pending arm. beginConnection reserves a new
                // token; the replaced arm's completion cannot confirm it (INV-PERSIST-3).
                // pinned: ChainedConnectLifecyclePolicyTests.testMissingGenerationRepairSupersedesAPendingArmWithoutConfirmingTheNewEpoch
                return beginConnection(state: &state, userInitiated: false, now: now)
            }
            guard state.pendingArm == nil else { return [] }
            state.armAttemptedConnection = nil
            var effects: [Effect] = []
            appendOnDemandIfNeeded(state: &state, connection: connection, effects: &effects)
            return effects
        case let .successFeedbackFinished(connection, retryWhenConfirmed):
            guard state.connection == connection, state.successFeedbackPending else { return [] }
            state.successFeedbackPending = false
            state.successFeedbackResolved = !retryWhenConfirmed
            return []
        case let .observationSuspended(now), let .observationResumed(now):
            guard state.status == .connected, state.samplingRequired else { return [] }
            observeGap(state: &state, now: now)
            return []
        case let .observationDeadline(connection, deadline, now):
            guard state.connection == connection, state.status == .connected,
                  state.graceDeadline == deadline, now >= deadline else { return [] }
            expireGap(state: &state)
            return []
        case let .teardownChanged(isActive):
            return reduceTeardown(state: &state, isActive: isActive)
        }
    }

    private static func reduceStatus(
        state: inout State,
        status: ProtectionLifecycleStatus,
        onDemandConfirmed: Bool,
        userInitiated: Bool,
        now: TimeInterval
    ) -> [Effect] {
        let previousStatus = state.status
        state.status = status
        state.onDemandConfirmed = onDemandConfirmed
        if onDemandConfirmed, status != .invalid {
            state.notice = .none
        }

        if status == .connected {
            guard previousStatus != .connected else { return [] }
            return beginConnection(state: &state, userInitiated: userInitiated, now: now)
        }

        var effects: [Effect] = []
        if previousStatus == .connected {
            if state.claim == .unconfirmed, !state.teardownActive {
                state.droppedUnconfirmedConnection = state.connection
            } else {
                state.droppedUnconfirmedConnection = nil
            }
            if state.samplingConnection != nil {
                state.samplingConnection = nil
                effects.append(.stopSampling)
            }
            state.samplingRequired = false
            state.setupReady = false
            state.claim = .inactive
            state.establishmentStartedAt = nil
            state.evidence = nil
            resetContinuity(state: &state)
        }

        guard isTerminal(status), let dropped = state.droppedUnconfirmedConnection else {
            return effects
        }
        defer { state.droppedUnconfirmedConnection = nil }
        guard !state.teardownActive else {
            state.notice = .none
            return effects
        }
        // Only a disconnected profile with a confirmed on-demand arm is known to recover. An
        // invalid status means there is no loaded profile, so a stale persisted confirmation must
        // not hide the reducer-owned vanish notice.
        if status == .disconnected, state.onDemandConfirmed {
            state.notice = .none
            return effects
        }
        if state.pendingArm?.connection == dropped {
            state.notice = .pending(connection: dropped)
        } else {
            state.notice = .visible(connection: dropped)
        }
        return effects
    }

    private static func beginConnection(
        state: inout State,
        userInitiated: Bool,
        now: TimeInterval
    ) -> [Effect] {
        let connection = state.nextConnectionID
        state.nextConnectionID += 1
        state.connection = connection
        state.claim = .establishing
        state.setupReady = false
        state.notice = .none
        state.samplingRequired = true
        state.establishmentStartedAt = now
        state.evidence = nil
        resetContinuity(state: &state)
        state.setupEvidenceInvalidated = false
        state.initialResolutionDone = false
        state.initialResolutionWasUserInitiated = userInitiated
        state.successFeedbackResolved = false
        state.successFeedbackPending = false
        state.armAttemptedConnection = nil
        state.droppedUnconfirmedConnection = nil

        guard !state.teardownActive else {
            state.samplingConnection = nil
            return []
        }
        state.samplingConnection = connection
        var effects: [Effect] = [.startSampling(connection: connection)]
        // Recovery follows the user's live connected intent, not the later forwarding claim. A
        // tunnel can disappear inside the configurable evidence window, so reserve the arm now; the
        // initial-resolution paths call the same idempotent helper and cannot create a second one.
        appendOnDemandIfNeeded(state: &state, connection: connection, effects: &effects)
        return effects
    }

    private static func reduceObservation(
        state: inout State,
        connection: UInt64,
        observation: ChainedRuntimeObservation?,
        now: TimeInterval
    ) -> [Effect] {
        guard state.status == .connected,
            state.connection == connection,
            state.samplingConnection == connection,
            !state.teardownActive
        else { return [] }

        switch observation {
        case .dnsOnly?:
            state.lastAcceptedAt = now
            state.gapStartedAt = nil
            state.runtimeCondition = .normal
            return confirmDNSOnly(state: &state, connection: connection)
        case let .chained(session: session?):
            state.lastAcceptedAt = now
            state.gapStartedAt = nil
            return observeSession(state: &state, connection: connection, session: session, now: now)
        case nil:
            observeGap(state: &state, now: now)
            if state.milestone != .none { return [] }
            return resolveTimeoutIfNeeded(state: &state, connection: connection,
                now: now, receivedByteDelta: nil)
        case .chained(session: nil)?, .inactive?:
            return observeMissingEvidence(state: &state, connection: connection, now: now)
        }
    }

    private static func confirmDNSOnly(state: inout State, connection: UInt64) -> [Effect] {
        // DNS-only returns health ownership to the regular DNS monitor before this sampler stops.
        state.ownsHealth = false
        state.connectivity = nil
        state.continuitySupported = false
        state.gapStartedAt = nil
        state.claim = .confirmed
        state.setupReady = false
        state.milestone = .forwardingVerified
        state.evidence = nil
        state.establishmentStartedAt = nil
        state.samplingRequired = false

        var effects: [Effect] = []
        if state.samplingConnection != nil {
            state.samplingConnection = nil
            effects.append(.stopSampling)
        }
        appendInitialResolutionIfNeeded(
            state: &state,
            connection: connection,
            confirmed: true,
            receivedByteDelta: nil,
            effects: &effects)
        appendOnDemandIfNeeded(state: &state, connection: connection, effects: &effects)
        return effects
    }

    private static func observeMissingEvidence(
        state: inout State,
        connection: UInt64,
        now: TimeInterval
    ) -> [Effect] {
        state.setupReady = false
        state.milestone = .none
        state.lastAcceptedAt = nil
        state.gapStartedAt = nil
        state.runtimeCondition = .retired
        // Retain ownership so persisted DNS health cannot replace an absent runner.
        // pinned: ChainedStatusContinuityTests.testRetiredRunnerClearsOwnedHealthUntilFreshEvidenceArrives
        state.connectivity = nil
        if state.evidence != nil { state.setupEvidenceInvalidated = true }
        if state.claim == .confirmed || state.claim == .checking {
            state.claim = .establishing
            state.establishmentStartedAt = now
            if let evidence = state.evidence {
                state.evidence = SessionEvidence(
                    generation: evidence.generation,
                    transportGeneration: evidence.transportGeneration,
                    providerLifecycleID: evidence.providerLifecycleID,
                    verificationEpoch: evidence.verificationEpoch,
                    baselineBytes: evidence.lastBytes,
                    lastBytes: evidence.lastBytes)
            }
        }
        return resolveTimeoutIfNeeded(
            state: &state,
            connection: connection,
            now: now,
            receivedByteDelta: nil)
    }

    private static func observeSession(
        state: inout State,
        connection: UInt64,
        session: ChainedRuntimeObservation.Session,
        now: TimeInterval
    ) -> [Effect] {
        state.runtimeCondition = session.runtimeCondition
        state.continuitySupported = session.providerLifecycleID != nil && session.verificationEpoch != nil
        state.ownsHealth = state.continuitySupported
        state.connectivity = session.health.map {
            ProtectionConnectivityPolicy.assessment(isConnected: true, health: $0,
                now: session.healthSampledAt ?? $0.updatedAt).severity
        }
        if let evidence = state.evidence {
            if session.generation != evidence.generation || session.transportGeneration != evidence.transportGeneration
                || session.providerLifecycleID != evidence.providerLifecycleID
                || session.verificationEpoch != evidence.verificationEpoch {
                state.setupEvidenceInvalidated = false
                state.milestone = .none
                state.evidence = SessionEvidence(
                    generation: session.generation,
                    transportGeneration: session.transportGeneration,
                    providerLifecycleID: session.providerLifecycleID,
                    verificationEpoch: session.verificationEpoch,
                    baselineBytes: session.forwardingBaseline,
                    lastBytes: session.forwardedBytes)
                restartEstablishment(state: &state, now: now)
            } else if session.forwardedBytes < evidence.lastBytes {
                state.setupEvidenceInvalidated = true
                state.milestone = .none
                state.evidence = SessionEvidence(
                    generation: session.generation,
                    transportGeneration: session.transportGeneration,
                    providerLifecycleID: session.providerLifecycleID,
                    verificationEpoch: session.verificationEpoch,
                    baselineBytes: session.forwardedBytes,
                    lastBytes: session.forwardedBytes)
                restartEstablishment(state: &state, now: now)
            } else {
                state.evidence = SessionEvidence(
                    generation: evidence.generation,
                    transportGeneration: evidence.transportGeneration,
                    providerLifecycleID: evidence.providerLifecycleID,
                    verificationEpoch: evidence.verificationEpoch,
                    baselineBytes: evidence.baselineBytes,
                    lastBytes: session.forwardedBytes)
            }
        } else {
            state.evidence = SessionEvidence(
                generation: session.generation,
                transportGeneration: session.transportGeneration,
                providerLifecycleID: session.providerLifecycleID,
                verificationEpoch: session.verificationEpoch,
                baselineBytes: session.forwardingBaseline,
                lastBytes: session.forwardedBytes)
            if state.initialResolutionDone, state.claim == .unconfirmed {
                restartEstablishment(state: &state, now: now)
            }
        }

        guard let evidence = state.evidence else { return [] }
        // Current negative runtime evidence wins immediately. Keep witnessed milestones only
        // so a healthy reply in this same epoch may restore them; no grace masks real failure.
        guard session.runtimeCondition == .normal else {
            state.setupReady = false
            state.claim = .checking
            return []
        }
        let forwardedByteDelta =
            session.forwardedBytes >= evidence.baselineBytes
            ? session.forwardedBytes - evidence.baselineBytes
            : 0
        let hasFreshForwarding =
            forwardedByteDelta >= ChainedEstablishmentPolicy.forwardingConfirmedByteThreshold
        if hasFreshForwarding {
            let isMeaningfulConfirmation = state.claim != .confirmed
            state.claim = .confirmed
            state.setupReady = false
            state.milestone = .forwardingVerified
            state.establishmentStartedAt = nil
            var effects: [Effect] = []
            appendInitialResolutionIfNeeded(
                state: &state,
                connection: connection,
                confirmed: true,
                receivedByteDelta: forwardedByteDelta,
                effects: &effects)
            // A failed arm reopens eligibility, but an unchanged already-confirmed poll must not
            // turn that into one retry per observation tick. Only a real claim transition — the
            // initial resolution or a later re-confirmation, including a replacement generation
            // that re-gates and confirms in one sample — consumes the reopened attempt.
            if isMeaningfulConfirmation {
                appendOnDemandIfNeeded(state: &state, connection: connection, effects: &effects)
            }
            return effects
        }

        let freshSetup = session.setupReady && !state.setupEvidenceInvalidated && session.generation != 0
            && (state.continuitySupported || (session.transportGeneration == 1 && session.forwardedBytes == 0))
        if freshSetup { state.milestone = .setupVerified }
        state.setupReady = freshSetup || (state.continuitySupported && state.milestone == .setupVerified)
        if state.setupReady {
            if state.claim == .checking { state.claim = .establishing }
            let firstResolution = !state.initialResolutionDone
            state.initialResolutionDone = true
            // Keep the forwarding deadline and recovery-arm retry independent of presentation.
            var effects = resolveTimeoutIfNeeded(state: &state, connection: connection,
                now: now, receivedByteDelta: forwardedByteDelta)
            // Setup resolves the explicit start, but leaves the forwarding reducer and monitor
            // running. Its single feedback token is shared with later actual confirmation.
            // Setup-only polls cannot retry feedback: only a later confirmed observation
            // may consume the still-available success opportunity.
            if firstResolution {
                state.successFeedbackPending = state.initialResolutionWasUserInitiated
                effects.append(.resolveSetupReady(connection: connection,
                    userInitiated: state.initialResolutionWasUserInitiated))
                appendOnDemandIfNeeded(state: &state, connection: connection, effects: &effects)
            }
            return effects
        }
        return resolveTimeoutIfNeeded(
            state: &state,
            connection: connection,
            now: now,
            receivedByteDelta: forwardedByteDelta)
    }

    private static func restartEstablishment(state: inout State, now: TimeInterval) {
        state.claim = .establishing
        state.setupReady = false
        state.establishmentStartedAt = now
    }

    private static func resetContinuity(state: inout State) {
        state.milestone = .none
        state.lastAcceptedAt = nil
        state.gapStartedAt = nil
        state.continuitySupported = false
        state.runtimeCondition = .normal
        state.connectivity = nil
        state.ownsHealth = false
    }

    private static func observeGap(state: inout State, now: TimeInterval) {
        if state.gapStartedAt == nil { state.gapStartedAt = now }
        guard state.milestone != .none else { return }
        guard let deadline = state.graceDeadline, now < deadline,
              state.runtimeCondition == .normal else {
            expireGap(state: &state)
            return
        }
    }

    private static func expireGap(state: inout State) {
        guard state.milestone != .none else { return }
        state.setupReady = false
        state.claim = .checking
        state.connectivity = nil
        state.runtimeCondition = .normal
    }

    private static func resolveTimeoutIfNeeded(
        state: inout State,
        connection: UInt64,
        now: TimeInterval,
        receivedByteDelta: UInt64?
    ) -> [Effect] {
        guard state.claim == .establishing,
            let startedAt = state.establishmentStartedAt,
            max(0, now - startedAt) >= establishmentTimeoutSeconds
        else { return [] }

        state.claim = .unconfirmed
        var effects: [Effect] = []
        appendInitialResolutionIfNeeded(
            state: &state,
            connection: connection,
            confirmed: false,
            receivedByteDelta: receivedByteDelta,
            effects: &effects)
        appendOnDemandIfNeeded(state: &state, connection: connection, effects: &effects)
        return effects
    }

    private static func appendInitialResolutionIfNeeded(
        state: inout State,
        connection: UInt64,
        confirmed: Bool,
        receivedByteDelta: UInt64?,
        effects: inout [Effect]
    ) {
        if state.initialResolutionDone {
            if confirmed, state.initialResolutionWasUserInitiated,
               state.connectivity == .healthy,
               state.runtimeCondition == .normal,
               !state.successFeedbackResolved, !state.successFeedbackPending {
                state.successFeedbackPending = true
                effects.append(.resolveDeferredSuccess(connection: connection, receivedByteDelta: receivedByteDelta))
            }
            return
        }
        state.initialResolutionDone = true
        state.successFeedbackPending = confirmed && state.initialResolutionWasUserInitiated
        effects.append(
            .resolveInitialClaim(
                connection: connection,
                confirmed: confirmed,
                userInitiated: state.initialResolutionWasUserInitiated,
                receivedByteDelta: receivedByteDelta))
    }

    private static func appendOnDemandIfNeeded(
        state: inout State,
        connection: UInt64,
        effects: inout [Effect]
    ) {
        guard state.armAttemptedConnection != connection else { return }
        state.armAttemptedConnection = connection
        guard !state.onDemandConfirmed, !state.teardownActive, state.status == .connected else {
            return
        }

        let id = state.nextArmID
        state.nextArmID += 1
        state.pendingArm = PendingArm(id: id, connection: connection)
        effects.append(.ensureOnDemand(id: id, connection: connection))
    }

    private static func reduceArmCompletion(
        state: inout State,
        id: UInt64,
        confirmed: Bool
    ) -> [Effect] {
        guard let pending = state.pendingArm, pending.id == id else {
            return [.reconcileProtectionStatus]
        }

        state.pendingArm = nil
        if confirmed {
            state.onDemandConfirmed = true
            if state.notice.connection == pending.connection {
                state.notice =
                    state.status == .invalid
                    ? .visible(connection: pending.connection)
                    : .none
            }
        } else {
            if state.status == .connected, state.connection == pending.connection {
                // Do not retry from the completion itself. Reopen the token for the next meaningful
                // resolution/promotion so a transient save failure gets one useful second chance
                // without creating a timer-driven retry loop.
                state.armAttemptedConnection = nil
            }
            if state.notice == .pending(connection: pending.connection) {
                state.notice = .visible(connection: pending.connection)
            }
        }
        return [.reconcileProtectionStatus]
    }

    private static func reduceTeardown(state: inout State, isActive: Bool) -> [Effect] {
        guard state.teardownActive != isActive else { return [] }
        state.teardownActive = isActive

        if isActive {
            state.setupReady = false
            state.droppedUnconfirmedConnection = nil
            state.notice = .none
            guard state.samplingConnection != nil else { return [] }
            state.samplingConnection = nil
            return [.stopSampling]
        }

        guard state.status == .connected,
            state.samplingRequired,
            state.samplingConnection == nil,
            let connection = state.connection
        else { return [] }
        state.samplingConnection = connection
        var effects: [Effect] = [.startSampling(connection: connection)]
        appendOnDemandIfNeeded(state: &state, connection: connection, effects: &effects)
        return effects
    }

    private static func isTerminal(_ status: ProtectionLifecycleStatus) -> Bool {
        status == .disconnected || status == .invalid
    }
}

fileprivate struct SessionEvidence: Equatable, Sendable {
    let generation: UInt64
    let transportGeneration: UInt64
    let providerLifecycleID: String?
    let verificationEpoch: UInt64?
    let baselineBytes: UInt64
    let lastBytes: UInt64
}

fileprivate struct PendingArm: Equatable, Sendable {
    let id: UInt64
    let connection: UInt64
}

private extension ChainedConnectLifecyclePolicy.Notice {
    var connection: UInt64? {
        switch self {
        case .none:
            nil
        case let .pending(connection), let .visible(connection):
            connection
        }
    }
}
