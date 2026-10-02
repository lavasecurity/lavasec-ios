import Foundation
import LavaSecKit

// Resolver execution/backoff and the provider-owned network-kind envelope update
// remain caller-owned. This reducer consumes one completed result summary and owns
// only session/episode evidence plus ordered semantic effects.

// All serving routes pass the same response-quality bar before earning service credit.
// Resolution keeps fallback coverage distinct from primary recovery evidence.
struct ResolverOrganicUpstreamEvidence: Equatable, Sendable {
    enum ResponseQuality: Equatable, Sendable {
        case acceptedAnswer
        case servedAnswer
    }

    enum Resolution: Equatable, Sendable {
        case selectedResolver(ResponseQuality)
        case encryptedFallback
        case deviceDNSFallback(primaryHadFallbackActivationEvidence: Bool)
    }

    enum AttemptOutcome: Equatable, Sendable {
        case success
        case timeout
        case httpStatusFailure
        case otherFailure
        /// The egress policy declined this transport; no wire attempt was made.
        ///
        /// Neither success nor failure, and it must be neither. Scoring a deliberate refusal
        /// as `otherFailure` increments `resolverFailureCounts` against the user's OWN
        /// resolver, so a session spent in chained mode would leave that resolver backed off
        /// when the tunnel later returns to DNS-only — punishing a resolver that never
        /// misbehaved, for a decision we made about it.
        case notAttempted

        init(_ outcome: ResolverAttemptOutcome) {
            switch outcome {
            case .success:
                self = .success
            case .timeout:
                self = .timeout
            case .httpStatusFailure:
                self = .httpStatusFailure
            case .refusedByEgressPolicy, .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced, .expiredBeforeSend,
                .tunnelInterfaceUnavailable, .physicalInterfaceUnavailable, .resolverPortUnavailable:
                // All are decisions WE made — an egress-policy refusal, a lifecycle-ended refusal,
                // the tunnel interface not being bound yet, F2's missing physical pin for a
                // floor-claimed destination, or our own port registry declining to name the source
                // port; see `isDeliberateRefusal`. None is a resolver fault, so none scores against
                // resolver health (Codex, PR #570).
                self = .notAttempted
            case .truncatedAnswer:
                // The resolver answered — promptly and correctly — that the response does
                // not fit UDP (S6, resolved decision 3: TC is liveness). For per-resolver
                // health that is a working resolver; scoring it as failure would count a
                // large-response domain against the upstream's own resolver. The client's
                // SERVFAIL is fail-closed policy, not resolver behaviour, and the
                // truncation itself is recorded via `udpTruncated`.
                self = .success
            case .backedOff,
                .sendFailed,
                .receiveFailed,
                .invalidAddress,
                .unsupported,
                .socketUnavailable,
                .mismatchedResponse,
                .unexpectedSourceResponse,
                .deviceDNSUnavailable:
                self = .otherFailure
            }
        }
    }

    struct Attempt: Equatable, Sendable {
        let address: String
        let outcome: AttemptOutcome
        let transport: DNSResolverTransport
        let negotiatedDoHProtocol: String?
    }

    enum Outcome: Equatable, Sendable {
        case totalFailure(reason: String?)
        case resolved(Resolution)
        /// The egress policy declined every transport; nothing was attempted.
        ///
        /// A third outcome because the other two are both wrong for it, and marking the
        /// per-attempt outcome `.notAttempted` was not enough: `response` is nil for a
        /// refusal, so the evidence still entered `reduceTotalFailure`, incrementing the
        /// upstream and consecutive failure counters, clearing accepted candidate evidence,
        /// and evaluating the recovery ladder. A deliberate refusal was still aggregate
        /// failure evidence — it just no longer named an address.
        ///
        /// Not `.resolved` either: nothing resolved, and counting it as success would tell the
        /// health model the upstream is fine when it was never asked.
        case declinedByPolicy
        /// While chained, the resolution was carried to the upstream's own resolver THROUGH
        /// THE TUNNEL, so its health is the outage supervisor's (`ChainedOutageDriver`), not
        /// this physical-DNS coordinator's. The physical reconnect wedge is meaningless while
        /// chained: a VPN restart cannot fix a conf resolver, it only re-latches chained and
        /// re-fails — the exact loop a device audit found (chimmy, 2026-08-14, a single conf
        /// resolver briefly backed off, every tunnelled query fail-closed `.backedOff`, three
        /// in a row crossed the reconnect threshold and the app showed a false "reconnect"
        /// while DNS was working). So this outcome is not only NEUTRAL like `.declinedByPolicy`
        /// but CLEARING: it resets the physical reconnect counters and drops any existing
        /// wedge, because while chained the physical path is not in use and its health is not
        /// a question this session has. The chained resolution's real outcome is scored by the
        /// supervisor's own observation door, which the provider reports separately.
        /// pinned: ResolverHealthOrganicEvidenceTests.testAChainedResolutionClearsAndDoesNotAccumulateThePhysicalReconnectWedge
        case governedByOutageSupervisor
        /// A tunnel-carried resolver answered that the response does not fit UDP (S6).
        ///
        /// A fourth outcome because the other three are each wrong for it. The TC answer is
        /// deliberately never relayed (the client gets the fail-closed SERVFAIL), so the
        /// result always carries a nil response — and the nil-response guard alone would
        /// sweep it into `.totalFailure`: upstream and consecutive failure counters plus
        /// reconnect effects, spent on a resolver that ANSWERED. That is the exact
        /// escalation resolved decision 3 forbids — one large-response domain must never
        /// read as a dead upstream (Codex, PR #511). Not `.resolved`: no bytes were served,
        /// and success credit here would feed recovery machinery `indicatesServedAnswer`
        /// deliberately gates on relayed bytes. Not `.declinedByPolicy`: a wire attempt
        /// happened and the resolver replied — a diagnostic that says "declined" would lie.
        case truncatedAnswer
    }

    let occurredAt: Date
    let outcome: Outcome
    let successfulResolverAddress: String?
    let observedResolverAddress: String?
    let transport: DNSResolverTransport
    let durationMilliseconds: Int?
    let udpTruncated: Bool
    let tcpFallbackAttempted: Bool
    let tcpFallbackSucceeded: Bool
    let deviceDNSFallbackAttempted: Bool
    let deviceDNSUnavailable: Bool
    let attempts: [Attempt]

    init(occurredAt: Date, result: DNSResolutionResult, chainedDataPathLatched: Bool = false, clientDeadlineExpired: Bool = false) {
        self.occurredAt = occurredAt
        successfulResolverAddress = result.successfulResolverAddress
        observedResolverAddress =
            result.successfulResolverAddress
            ?? result.attempts.last?.address
        transport = result.transport
        durationMilliseconds = result.durationMilliseconds
        udpTruncated = result.udpTruncated
        tcpFallbackAttempted = result.tcpFallbackAttempted
        tcpFallbackSucceeded = result.tcpFallbackSucceeded
        deviceDNSFallbackAttempted = result.deviceDNSFallbackAttempted
        deviceDNSUnavailable = result.deviceDNSUnavailable
        attempts = result.attempts.map { attempt in
            Attempt(
                address: attempt.address,
                outcome: AttemptOutcome(attempt.outcome),
                transport: attempt.transport,
                negotiatedDoHProtocol: attempt.negotiatedDoHProtocol
            )
        }

        // Checked FIRST, ahead of every physical-DNS classification below, because while
        // chained NONE of them apply: the resolution was carried through the tunnel to the
        // conf's own resolver, so its success or failure is the outage supervisor's to score,
        // and the physical reconnect wedge those classifications feed is moot (a VPN restart
        // cannot fix a conf resolver). The per-resolver and aggregate fields set above are
        // still recorded for diagnostics; only the physical verdict is withheld — and, unique
        // to this outcome, any existing physical wedge is cleared, since chained mode means the
        // physical path is not in use. See `Outcome.governedByOutageSupervisor`.
        if chainedDataPathLatched {
            outcome = .governedByOutageSupervisor
            return
        }

        // Preserve real attempts after client expiry, but a late reply cannot earn service credit.
        // Queue-only expiry says nothing about the endpoint and remains neutral.
        // pinned: ResolverHealthOrganicEvidenceTests.testClientExpiryPreservesFailureEvidenceWithoutServiceCredit
        if clientDeadlineExpired {
            outcome = result.attempts.contains { $0.outcome.reachedTheWire }
                ? .totalFailure(reason: "query-deadline-expired")
                : .declinedByPolicy
            return
        }

        // A resolution ABANDONED because its session ended is not a verdict on anything, even
        // when earlier rungs really did fail. `allSatisfy` cannot express that: the ladder
        // gate produces `[.receiveFailed, .refusedAfterLifecycleEnded]` whenever a rung failed
        // before the stop, which is the ordinary case — one real failure, then the abandon —
        // and that mixture fell through to `.totalFailure`, advancing the escalation ladder
        // for a tunnel that merely stopped (Kilo, PR #524).
        //
        // The LAST attempt is what decides, because it says how the resolution ENDED: the
        // remaining endpoints were never tried, so "every resolver failed" is not something
        // this result establishes. The per-resolver evidence for the rungs that did run is
        // assembled above and keeps its own scoring; only the aggregate verdict is withheld.
        // Terminal refusals use the shared category. A rung refused because its DATA PATH was
        // replaced is just as abandoned as one refused because its session ended: nothing was
        // sent, so scoring it a failure would advance aggregate outage and recovery state for a
        // resolution the device chose not to make (PR #610).
        if result.attempts.last?.outcome.endsTheResolutionLadder == true {
            outcome = .declinedByPolicy
            return
        }

        // A refusal is not a failure of anything. Checked BEFORE the nil-response guard,
        // because a refusal always has a nil response and would otherwise be swept into the
        // total-failure path by that alone.
        if !result.attempts.isEmpty,
           result.attempts.allSatisfy({ $0.outcome.isDeliberateRefusal })
        {
            outcome = .declinedByPolicy
            return
        }

        // A truncated tunnel answer also always has a nil response — the TC answer is never
        // relayed — so it is classified before the same guard, for the same reason as the
        // refusal above (S6, resolved decision 3).
        //
        // THE LAST ATTEMPT THAT ACTUALLY REACHED A RESOLVER DECIDES, which is the same rule
        // ordinary failover already runs on: `[.timeout, .success]` is a resolution whose
        // timeout is scored per-resolver, not an aggregate failure. Two earlier readings
        // were each wrong in one direction — `contains` let one truncation shield every
        // genuine failure beside it, and `allSatisfy` made a failover that ENDED in
        // truncation (`[.timeout, .truncatedAnswer]`) an aggregate failure, spending the
        // outage budget although the later resolver had just proved the chained path alive
        // (Codex, PR #511). Refusals are skipped when looking for the decisive attempt
        // because they are already neutral: a refused fallback rung after a truncation says
        // nothing about the resolver that answered.
        //
        // The nil-response condition is load-bearing the other way: a failover where one
        // endpoint answered TC and a LATER one served real bytes carries a response, and
        // that result is a resolution, not a truncation.
        let decisiveAttempt = result.attempts.last { !$0.outcome.isDeliberateRefusal }
        if result.response == nil, decisiveAttempt?.outcome == .truncatedAnswer {
            outcome = .truncatedAnswer
            return
        }

        guard result.response != nil else {
            outcome = .totalFailure(reason: result.failureSummary)
            return
        }

        let responseQuality: ResponseQuality
        if DNSResolverSmokeProbe.indicatesAcceptedAnswer(result.response) {
            responseQuality = .acceptedAnswer
        } else if DNSResolverSmokeProbe.indicatesServedAnswer(result.response) {
            responseQuality = .servedAnswer
        } else {
            // A packet arrived, but no tier served the query. Per-attempt transport metrics
            // still record reachability; the failure reducer cannot stamp primary/fallback credit.
            outcome = .totalFailure(reason: "upstream-response-failed")
            return
        }

        let resolution: Resolution
        if result.usedEncryptedFallback {
            resolution = .encryptedFallback
        } else if result.deviceDNSFallbackSucceeded {
            resolution = .deviceDNSFallback(
                primaryHadFallbackActivationEvidence: result.hasFallbackActivationEvidence)
        } else {
            resolution = .selectedResolver(responseQuality)
        }
        outcome = .resolved(resolution)
    }
}

enum ResolverOrganicEvidenceReducer {
    private static let encryptedFallbackCoverageClearFailureThreshold = 3
    private static let slowUpstreamResponseThresholdMilliseconds = 2_500

    static func reduce(
        state: ResolverHealthEvidenceState,
        evidence: ResolverOrganicUpstreamEvidence,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        var next = state
        next.session.lastResolverAddress = evidence.observedResolverAddress
        next.session.lastResolverTransport = evidence.transport
        next.session.lastUpstreamDurationMilliseconds = evidence.durationMilliseconds

        switch evidence.outcome {
        case .governedByOutageSupervisor:
            return reduceGovernedByOutageSupervisor(state: &next)

        case .totalFailure(let reason):
            return reduceTotalFailure(
                state: &next,
                evidence: evidence,
                reason: reason,
                projectingOnto: snapshot
            )

        case .resolved(let resolution):
            return reduceResolved(
                state: &next,
                evidence: evidence,
                resolution: resolution,
                projectingOnto: snapshot
            )

        case .declinedByPolicy:
            // Neutral for the AGGREGATE verdict — no consecutive-failure counter, no
            // candidate-evidence reset, no recovery ladder — because nothing was concluded
            // about the upstream. The last-resolver fields above are still recorded, since
            // "which resolver did we decline" is the diagnostic.
            //
            // Attempt metrics DO apply, and this arm used to skip them. That was invisible
            // while the only way here was an all-refused result, whose attempts are every one
            // `.notAttempted` and skipped anyway. An ABANDONED ladder is the shape that made
            // it visible: `[.receiveFailed, .refusedAfterLifecycleEnded]` carries one rung
            // that really reached a resolver and really failed, and dropping it lost that
            // endpoint from `resolverAttemptCounts`/`resolverFailureCounts` — while the
            // comment beside it claimed per-resolver scoring was retained (Codex P2, PR #524).
            // The refusal itself maps to `.notAttempted` and is still skipped, so the
            // all-refused case is unchanged.
            applyAttemptMetrics(evidence, to: &next)
            // Effects only when something actually moved. An all-refused result skips every
            // attempt (each maps to `.notAttempted`), so this stays exactly as neutral as it
            // has always been — no counters, no persist, no projection — which
            // `testAnEgressRefusalIsNeutralAtTheAGGREGATELevelToo` asserts. An abandoned
            // ladder DID record a real failure, and without the persist a process death
            // loses it, so that case emits the same two effects as every other
            // counter-mutating arm.
            guard evidence.attempts.contains(where: { $0.outcome != .notAttempted }) else {
                return ResolverHealthTransitionSupport.transition(state: next, effects: [])
            }
            // IMMEDIATE, not deferred, and this is the one arm where that distinction is
            // load-bearing rather than a preference. Every other counter-mutating path runs
            // inside a live session that will flush again on its own cadence; this one runs
            // BY DEFINITION after the session ended, and stop cleanup has already taken its
            // forced flush. A `.deferred` write schedules up to the debounce interval later,
            // after `stopTunnel` has signalled completion and NetworkExtension may suspend or
            // terminate — so the metrics this arm exists to recover would be the ones most
            // reliably lost (Codex P2, PR #524).
            return ResolverHealthTransitionSupport.transition(
                state: next,
                effects: [.signalConnectivityProjectionChanged, .persistHealth(.immediate)])

        case .truncatedAnswer:
            // Neutral for FAILURE scoring — no upstream or consecutive failure counters, no
            // candidate reset, no recovery-ladder effects — but unlike a refusal the wire
            // was reached, so the attempt metrics still apply: `udpTruncatedResponseCount`
            // and the per-resolver counts keep recording a resolver that answered. No
            // success credit beyond that: recovery is gated on relayed bytes
            // (`indicatesServedAnswer`), and a TC answer is deliberately never relayed. The
            // liveness half of TC is the outage supervisor's to score, through the driver's
            // observation door — chained health lives there, not in this coordinator.
            applyAttemptMetrics(evidence, to: &next)
            // Counters moved, so the snapshot is dirty and the projection changed — the
            // same two effects every other counter-mutating arm emits (`.declinedByPolicy`
            // now emits them too, for the abandoned-ladder case); this arm increments
            // `udpTruncatedResponseCount` and the per-resolver tallies, and without the
            // persist a TC burst followed by process death loses them.
            return ResolverHealthTransitionSupport.transition(
                state: next,
                effects: [.signalConnectivityProjectionChanged, .persistHealth(.deferred)])
        }
    }

    /// While chained, physical-DNS health is not in play: the resolution was tunnelled to the
    /// conf's own resolver, whose liveness the outage supervisor scores through its own door.
    /// This reducer therefore withholds every physical verdict AND clears any physical wedge —
    /// the reconnect episode and the failure/slow counters that feed it — because a physical
    /// reconnect cannot fix a chained path and would only loop (chimmy, 2026-08-14: a single
    /// conf resolver briefly backed off, three fail-closed `.backedOff` results crossed the
    /// reconnect threshold, and the app showed a false "reconnect" while DNS was working). It
    /// credits NO success either: a tunnelled answer is not evidence the PHYSICAL resolver
    /// recovered. Per-resolver attempt metrics are deliberately not applied, so a chained
    /// session never scores the user's own resolver into the physical ledger it would be
    /// judged by after returning to DNS-only (the same concern `AttemptOutcome.notAttempted`
    /// records for refusals).
    private static func reduceGovernedByOutageSupervisor(
        state: inout ResolverHealthEvidenceState
    ) -> ResolverHealthTransition {
        let hadPhysicalWedge =
            state.reconnectEpisode != nil
            || state.episode.consecutiveUpstreamFailureCount > 0
            || state.session.consecutiveSlowUpstreamResponseCount > 0
        state.episode.consecutiveUpstreamFailureCount = 0
        state.session.consecutiveSlowUpstreamResponseCount = 0
        state.reconnectEpisode = nil
        // The physical-failure remnants the app SURFACES are cleared too — a stale "last failure
        // reason" left standing while chained is the false-failure signal this outcome removes —
        // but ONLY when a physical wedge actually stood behind them. A `lastFailureReason` with
        // NO wedge belongs to another subsystem (e.g. a `.networkSettingsReapplyFailed` that has
        // not recovered), so an unrelated chained completion must not erase it (Codex P2). When a
        // wedge did stand, its reason and timestamp go with the counters that drove it.
        if hadPhysicalWedge {
            state.episode.lastFailureReason = nil
            state.session.lastUpstreamFailureAt = nil
        }
        // Effects only when something actually moved, mirroring `.declinedByPolicy`: a steady
        // chained session with no physical wedge to clear stays silent rather than reposting an
        // unchanged projection on every served query.
        guard hadPhysicalWedge else {
            return ResolverHealthTransitionSupport.transition(state: state, effects: [])
        }
        return ResolverHealthTransitionSupport.transition(
            state: state,
            effects: [.signalConnectivityProjectionChanged, .persistHealth(.deferred)])
    }

    private static func reduceTotalFailure(
        state: inout ResolverHealthEvidenceState,
        evidence: ResolverOrganicUpstreamEvidence,
        reason: String?,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        // INV-DNS-4: candidate evidence resets on a total failure, but an active network-
        // episode mode stays latched until recovery or a real context reset.
        // pinned: ResolverHealthSmokeEvidenceTests.testActiveFallbackModeRemainsStickyAfterOrganicFailureClearsCandidateCount
        state.episode.deviceDNSFallbackEvidenceCount = 0
        state.session.consecutiveSlowUpstreamResponseCount = 0
        state.session.upstreamFailureCount += 1
        state.episode.consecutiveUpstreamFailureCount += 1
        state.episode.lastFailureReason = reason
        state.session.lastUpstreamFailureAt = evidence.occurredAt
        state.episode.consecutiveCarriedQueryFailureCount += 1
        if state.episode.consecutiveCarriedQueryFailureCount
            >= encryptedFallbackCoverageClearFailureThreshold
        {
            state.episode.lastEncryptedFallbackSuccessAt = nil
        }
        state.episode.lastAcceptedPrimaryEvidenceAt = nil
        applyAttemptMetrics(evidence, to: &state)

        var effects: [ResolverHealthEffect] = [
            .signalConnectivityProjectionChanged,
            .persistHealth(.deferred),
        ]
        ResolverHealthTransitionSupport.appendReconnectEffects(
            to: &effects,
            state: &state,
            projectingOnto: snapshot,
            at: evidence.occurredAt,
            rearmWedgeProbeForExistingEvidence: false
        )
        effects.append(
            .evaluateQAConnectivityLog(reason: "upstream-failure", at: evidence.occurredAt)
        )
        return ResolverHealthTransitionSupport.transition(state: state, effects: effects)
    }

    private static func reduceResolved(
        state: inout ResolverHealthEvidenceState,
        evidence: ResolverOrganicUpstreamEvidence,
        resolution: ResolverOrganicUpstreamEvidence.Resolution,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthTransition {
        let wasFallbackModeActive = state.episode.deviceDNSFallbackModeActive
        let isDeviceDNSQueryFallback: Bool
        if case .deviceDNSFallback = resolution {
            isDeviceDNSQueryFallback = true
        } else {
            isDeviceDNSQueryFallback = false
        }
        state.session.upstreamSuccessCount += 1
        state.session.lastUpstreamSuccessAt = evidence.occurredAt
        state.episode.lastFailureReason = nil
        state.episode.consecutiveUpstreamFailureCount = 0
        state.episode.consecutiveCarriedQueryFailureCount = 0

        var effects: [ResolverHealthEffect] = []
        var endedFallbackLogEpisode = false
        var activatedFallbackMode = false
        switch resolution {
        case .encryptedFallback:
            state.episode.lastAcceptedPrimaryEvidenceAt = nil
            state.episode.lastEncryptedFallbackSuccessAt = evidence.occurredAt
            effects.append(.scheduleWedgeRecoveryProbe)

        case .selectedResolver(let responseQuality):
            let resolvedThroughFallbackMode =
                evidence.transport == .deviceDNS && wasFallbackModeActive
            if !resolvedThroughFallbackMode {
                applySelectedPrimaryEvidence(
                    responseQuality,
                    occurredAt: evidence.occurredAt,
                    to: &state
                )
                state.episode.lastEncryptedFallbackSuccessAt = nil
            }
            endedFallbackLogEpisode = appendNonEncryptedRecoveryEffects(
                to: &effects,
                state: &state,
                transport: evidence.transport,
                recoveredAt: evidence.occurredAt,
                projectingOnto: snapshot
            )

        case .deviceDNSFallback(let primaryHadFallbackActivationEvidence):
            endedFallbackLogEpisode = appendNonEncryptedRecoveryEffects(
                to: &effects,
                state: &state,
                transport: evidence.transport,
                recoveredAt: evidence.occurredAt,
                projectingOnto: snapshot
            )
            state.episode.lastAcceptedPrimaryEvidenceAt = nil
            state.session.deviceDNSFallbackSuccessCount += 1
            state.episode.deviceDNSFallbackEvidenceCount =
                DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
                    currentCount: state.episode.deviceDNSFallbackEvidenceCount,
                    primaryResolverWasAttempted:
                        primaryHadFallbackActivationEvidence
                )
            if wasFallbackModeActive {
                state.episode.deviceDNSFallbackModeActive = true
            } else if DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                consecutiveQueryFallbackSuccesses:
                    state.episode.deviceDNSFallbackEvidenceCount
            ) {
                state.episode.deviceDNSFallbackModeActive = true
                state.episode.lastDeviceDNSFallbackActivatedAt = evidence.occurredAt
                state.session.deviceDNSFallbackActivationCount += 1
                activatedFallbackMode = true
            }
        }

        applyLatencyMetrics(evidence, to: &state)
        if !isDeviceDNSQueryFallback, evidence.transport != .deviceDNS {
            state.episode.deviceDNSFallbackEvidenceCount = 0
        }
        applyAttemptMetrics(evidence, to: &state)

        let recoveredFallbackMode: Bool
        if wasFallbackModeActive,
            evidence.transport != .deviceDNS,
            !isDeviceDNSQueryFallback
        {
            state.episode.deviceDNSFallbackModeActive = false
            state.episode.lastDeviceDNSFallbackActivatedAt = nil
            state.episode.deviceDNSFallbackEvidenceCount = 0
            effects.append(.cancelFallbackRecoveryProbe)
            recoveredFallbackMode = true
        } else {
            recoveredFallbackMode = false
        }

        effects.append(contentsOf: [
            .signalConnectivityProjectionChanged,
            .persistHealth(.deferred),
        ])
        if recoveredFallbackMode {
            effects.append(
                .appendNetworkActivity(.deviceDNSFallbackRecovered, at: evidence.occurredAt)
            )
        }
        if activatedFallbackMode {
            effects.append(
                .appendNetworkActivity(
                    .deviceDNSFallbackActivated(reason: "query-fallback"),
                    at: evidence.occurredAt
                )
            )
        }
        if isDeviceDNSQueryFallback {
            effects.append(.scheduleFallbackRecoveryProbe)
        }
        switch resolution {
        case .encryptedFallback:
            effects.append(
                .recordEncryptedFallbackCarry(
                    ResolverEncryptedFallbackCarry(
                        occurredAt: evidence.occurredAt,
                        transport: evidence.transport,
                        resolverAddress: evidence.successfulResolverAddress
                    )
                )
            )
        case .selectedResolver,
            .deviceDNSFallback:
            break
        }
        if case .selectedResolver = resolution,
            !endedFallbackLogEpisode
        {
            effects.append(.endEncryptedFallbackLogEpisode(.episodeEnd))
        }
        effects.append(
            .evaluateQAConnectivityLog(reason: "upstream-success", at: evidence.occurredAt)
        )
        effects.append(.evaluateProtectionNotification(at: evidence.occurredAt))
        return ResolverHealthTransitionSupport.transition(state: state, effects: effects)
    }

    private static func applySelectedPrimaryEvidence(
        _ responseQuality: ResolverOrganicUpstreamEvidence.ResponseQuality,
        occurredAt: Date,
        to state: inout ResolverHealthEvidenceState
    ) {
        switch responseQuality {
        case .acceptedAnswer:
            state.session.lastPrimaryUpstreamSuccessAt = occurredAt
            state.episode.lastAcceptedPrimaryEvidenceAt = occurredAt
            state.episode.consecutiveSmokeProbeFailureCount = 0
        case .servedAnswer:
            state.session.lastPrimaryUpstreamSuccessAt = occurredAt
            state.episode.consecutiveSmokeProbeFailureCount = 0
        }
    }

    private static func appendNonEncryptedRecoveryEffects(
        to effects: inout [ResolverHealthEffect],
        state: inout ResolverHealthEvidenceState,
        transport: DNSResolverTransport,
        recoveredAt: Date,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> Bool {
        var endedFallbackLogEpisode = false
        if let recovery = ResolverHealthTransitionSupport.takeRecovery(
            from: &state,
            transport: transport,
            recoveredAt: recoveredAt,
            verifiedBy: "forwarding",
            projectingOnto: snapshot
        ) {
            effects.append(.reportConnectivityRecovery(recovery))
            effects.append(.endEncryptedFallbackLogEpisode(.episodeEnd))
            endedFallbackLogEpisode = true
        }
        state.effectDelivery.lastReconnectNeededActivityAt = nil
        effects.append(.cancelWedgeRecoveryProbe)
        effects.append(.clearDeviceDNSRecaptureRestartPending)
        return endedFallbackLogEpisode
    }

    private static func applyLatencyMetrics(
        _ evidence: ResolverOrganicUpstreamEvidence,
        to state: inout ResolverHealthEvidenceState
    ) {
        // Fold resolved-query round-trip latency into the session histogram AND record it
        // as the last *successful* response duration for the Nerd Stats rows
        // (plans/2026-07-11-nerd-stats-dns-latency-plan.md). Only resolved queries reach
        // here (reduceResolved), matching the slow-response metrics below — total failures
        // stay in the failure counters and never skew the distribution or the "Last DNS
        // response" row. `lastUpstreamDurationMilliseconds` (set for failures too, earlier)
        // is a separate raw "what just happened" readout and is unaffected.
        if let durationMilliseconds = evidence.durationMilliseconds {
            state.session.upstreamLatencyHistogram.record(durationMilliseconds: durationMilliseconds)
            state.session.lastUpstreamSuccessDurationMilliseconds = durationMilliseconds
        }
        if let durationMilliseconds = evidence.durationMilliseconds,
            durationMilliseconds >= slowUpstreamResponseThresholdMilliseconds
        {
            state.session.slowUpstreamResponseCount += 1
            state.session.consecutiveSlowUpstreamResponseCount += 1
            state.session.lastSlowUpstreamResponseAt = evidence.occurredAt
        } else {
            state.session.consecutiveSlowUpstreamResponseCount = 0
        }
    }

    private static func applyAttemptMetrics(
        _ evidence: ResolverOrganicUpstreamEvidence,
        to state: inout ResolverHealthEvidenceState
    ) {
        if evidence.udpTruncated {
            state.session.udpTruncatedResponseCount += 1
        }
        if evidence.tcpFallbackAttempted {
            state.session.tcpFallbackAttemptCount += 1
        }
        if evidence.tcpFallbackSucceeded {
            state.session.tcpFallbackSuccessCount += 1
        }
        if evidence.deviceDNSFallbackAttempted {
            state.session.deviceDNSFallbackAttemptCount += 1
        }
        if evidence.deviceDNSUnavailable {
            state.session.deviceDNSUnavailableCount += 1
        }

        // The `.notAttempted` filter the previous comment here predicted, now real: S6 is
        // the mode that refuses SOME transports while attempting others, so a tunnelled
        // `.plainDNS` attempt can sit beside a refused fallback rung in one result. The
        // all-refusals shape still diverts to `.declinedByPolicy` before this runs; the
        // mixed shape reaches here, and a refusal must not join the attempt denominator or
        // a healthy resolver reads as intermittent.
        for attempt in evidence.attempts {
            guard attempt.outcome != .notAttempted else { continue }
            state.session.resolverAttemptCounts[attempt.address, default: 0] += 1
            switch attempt.outcome {
            case .success:
                state.session.resolverSuccessCounts[attempt.address, default: 0] += 1
                if attempt.transport == .dnsOverHTTPS,
                    let negotiatedDoHProtocol = attempt.negotiatedDoHProtocol
                {
                    state.session.lastDoHHTTPVersion = negotiatedDoHProtocol
                }
            case .timeout:
                state.session.upstreamTimeoutCount += 1
                state.session.resolverFailureCounts[attempt.address, default: 0] += 1
            case .httpStatusFailure:
                state.session.dohHTTPFailureCount += 1
                state.session.resolverFailureCounts[attempt.address, default: 0] += 1
            case .otherFailure:
                state.session.resolverFailureCounts[attempt.address, default: 0] += 1
            case .notAttempted:
                // Deliberately no counter. Nothing was attempted and nothing went wrong.
                break
            }
        }
    }

}
