@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecChainedUpstream
import LavaSecDNS
import LavaSecFilterPipeline
import LavaSecKit

// One concern of `PacketTunnelProvider`, split out of the former single-file provider.
// Stored state lives in LavaSecTunnel/PacketTunnelProvider.swift (extensions cannot declare
// stored properties, so a property declared beside its concern moved there); the other
// `PacketTunnelProvider+*.swift` files each hold one `// MARK:` section of the class, and the
// remaining files under Provider/ hold the types the single file declared outside it.

extension PacketTunnelProvider {
    // MARK: - Smoke probe scheduling & result application

    func scheduleResolverSmokeProbeIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleResolverSmokeProbeIfNeeded(reason: reason)
            }
            return
        }

        guard tunnelLifecycleIsActive else {
            return
        }

        // NOT SCHEDULED AT ALL while chained, which is a different thing from being refused
        // when it runs.
        //
        // Refusal is already correct: the probe's primary goes through
        // `resolverOrchestrator`, whose allowance reads the latched mode, and its device-DNS
        // fallback is guarded at the direct call. `ResolverHealthEvidence` and
        // `ResolverHealthOrganicEvidence` both classify an all-refused result as
        // `declinedByPolicy` rather than a failure, so the health ladder is not corrupted
        // either. Nothing leaks.
        //
        // What running it anyway costs is real all the same. `lastWireSmokeProbeAt` and the
        // `smokeProbeWire` counter are stamped BEFORE the resolution, so every suppressed probe
        // records a wire query that never reached the wire — and NRG-3a's evidence-age
        // suppression keys on that stamp, so the diagnostics lie about the one thing they exist
        // to measure. On top of that the extension wakes on the probe interval, schedules a
        // timeout, and runs the completion machinery to learn something structurally
        // unavailable: while chained, the physical-interface resolver is not the path in use,
        // so its health is not a question this session has.
        //
        // Chained mode has its own health signal — the outage supervisor — and it is measured
        // from traffic through the tunnel, not from a canary the tunnel routed away from.
        // pinned: TunnelDataPathLatchSourceTests.testTheSmokeProbeIsNotScheduledWhileChained
        guard permitsPhysicalInterfaceDNS() else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-skipped", details: [
                "reason": reason,
                "cause": "chained-upstream"
            ])
            #if DEBUG || LAVA_QA_TOOLS
            EnergyCounters.shared.bump(.smokeProbeSkip)   // NRG smoke-probe lever: chained mode has no physical-interface resolver to probe
            #endif
            return
        }

        let schedulingView = currentResolverHealthSchedulingView()
        guard schedulingView.networkPathIsSatisfied else {
            return
        }

        // NRG-3a: the routine tick — and ONLY the routine tick; every other reason
        // (wedge, fallback-recovery, settle, config-change, startTunnel) stays
        // unconditional — skips the wire probe when equivalent evidence already
        // exists. "Equivalent" requires ALL of: a fully-healthy ladder (any nonzero
        // streak, active fallback mode, or armed wedge marker means mid-incident,
        // where there is no equivalence and skipping would freeze the LAV-87
        // escalation), and acceptance-checked primary evidence younger than one
        // probe interval. The staleness guarantee is unchanged: real traffic that
        // passed the probe's own acceptance check IS fresher proof than a probe.
        if reason == "periodic-health-check",
           schedulingView.consecutiveRejectedResponseCount == 0,
           schedulingView.consecutiveSmokeProbeFailureCount == 0,
           schedulingView.consecutiveUpstreamFailureCount == 0,
           !schedulingView.deviceDNSFallbackModeActive,
           !schedulingView.reconnectEpisodeIsActive,
           let evidenceAt = schedulingView.lastAcceptedPrimaryEvidenceAt {
            // Future-dated evidence (a backward wall-clock jump after the stamp) must
            // NOT skip: a negative age would satisfy an upper bound alone until the
            // clock caught up — indefinitely suppressing routine probes. Out-of-range
            // evidence in either direction just means "probe normally".
            let evidenceAge = Date().timeIntervalSince(evidenceAt)
            if evidenceAge >= 0, evidenceAge <= Self.resolverSmokeProbeInterval {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-skipped", details: [
                    "reason": reason,
                    "evidenceAgeMs": "\(Int(evidenceAge * 1_000))"
                ])
                #if DEBUG || LAVA_QA_TOOLS
                EnergyCounters.shared.bump(.smokeProbeSkip)   // NRG smoke-probe lever: NRG-3a suppressed the wire query
                #endif
                return
            }
        }

        // UR-48 Phase 2a: chronic-failure backoff — the routine tick, and ONLY the routine
        // tick (same scoping rule as NRG-3a above: every event-driven reason stays
        // unconditional, so wedge/recovery/settle/config/start probes are never delayed).
        // Past the activation streak, skip the wire query until the adaptive interval since
        // the last wire probe has elapsed. The interval keys on the LIVE consecutive-failure
        // counter, which resets on any probe success, recovery, and network-path change —
        // so leaving backoff is instant on every real change signal. A negative elapsed
        // (wall clock set backwards) probes normally rather than trusting a future stamp,
        // mirroring the NRG-3a evidence-age guard.
        if reason == "periodic-health-check",
           schedulingView.consecutiveSmokeProbeFailureCount >= DeviceDNSFallbackPolicy.smokeProbeBackoffActivationFailureCount,
           let lastWireSmokeProbeAt {
            let requiredInterval = DeviceDNSFallbackPolicy.routineSmokeProbeInterval(
                afterConsecutiveFailures: schedulingView.consecutiveSmokeProbeFailureCount
            )
            let sinceLastWireProbe = Date().timeIntervalSince(lastWireSmokeProbeAt)
            if sinceLastWireProbe >= 0, sinceLastWireProbe < requiredInterval {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-skipped", details: [
                    "reason": reason,
                    "chronicFailures": "\(schedulingView.consecutiveSmokeProbeFailureCount)",
                    "backoffIntervalS": "\(Int(requiredInterval))",
                    "sinceLastProbeS": "\(Int(sinceLastWireProbe))"
                ])
                #if DEBUG || LAVA_QA_TOOLS
                EnergyCounters.shared.bump(.smokeProbeSkip)   // NRG smoke-probe lever: chronic backoff suppressed the wire query
                #endif
                return
            }
        }

        let resolverConfiguration = currentResolverRuntimeConfiguration(
            ignoresDeviceDNSFallbackMode: true,
            allowsQueryFallback: false
        )
        let canUseDeviceDNSFallback = currentAppConfiguration().fallbackToDeviceDNS
            && resolverConfiguration.transport != .deviceDNS
            && !resolverConfiguration.deviceDNSFallbackAddresses.isEmpty
        #if DEBUG || LAVA_QA_TOOLS
        EnergyCounters.shared.bump(.smokeProbeWire)   // NRG smoke-probe lever: this probe hits the wire (radio wake)
        EnergySignpost.event("smoke-probe-wire")      // NRG Phase 2: mark the radio wake for Instruments
        #endif
        lastWireSmokeProbeAt = Date()
        let probeStart = resolverHealthCoordinator.assumeIsolated { $0.beginSmokeProbe() }
        // Rotate the canary domain per probe so a single blocked/hijacked domain
        // can't sustain a false "unhealthy" verdict (a different domain's success
        // resets the consecutive-failure count); a resolver that refuses them all
        // still escalates.
        let probeDomain = DNSResolverSmokeProbe.probeDomain(forSequence: probeStart.rotationSequence)
        let query = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: probeDomain
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-begin", details: [
            "reason": reason,
            "transport": resolverConfiguration.transport.rawValue,
            "canUseDeviceDNSFallback": "\(canUseDeviceDNSFallback)"
        ])

        // Captured on dnsStateQueue, before the probe hops to its own queue — same reason as
        // the forwarding paths: the work is ACCEPTED here and resolves later.
        let admittedAtEpoch = currentResolverAdmissionEpoch()
        // And the RESOLVER RUNTIME the probe is about to exercise, for the rung's credit fence
        // (`TierOneRungCreditTiming.noClient`). Free here — this is already dnsStateQueue, so the
        // accessor takes its re-entrant path rather than hopping.
        let admittedAtRuntimeGeneration = currentResolverRuntimeGeneration()
        let admittedAtTierContext = currentResolverTierContextIdentity()
        runResolverSmokeProbeWork { [weak self] finish in
            guard let self else {
                finish()
                return
            }

            let timeout = ResolverSmokeProbeTimeout { [weak self] in
                guard let self else {
                    finish()
                    return
                }

                self.dnsStateQueue.async { [weak self] in
                    guard let self else {
                        finish()
                        return
                    }

                    let timeoutResult = self.resolverSmokeProbeTimeoutResult(
                        resolverConfiguration: resolverConfiguration
                    )
                    self.completeResolverSmokeProbeResult(
                        token: probeStart.token,
                        reason: reason,
                        primaryResult: timeoutResult,
                        primarySucceeded: false,
                        fallbackResult: nil,
                        fallbackSucceeded: false
                    )
                    finish()
                }
            }
            timeout.schedule(on: dnsStateQueue, timeoutSeconds: Self.smokeProbeTimeoutSeconds(
                reason: reason,
                transport: resolverConfiguration.transport,
                canUseDeviceDNSFallback: canUseDeviceDNSFallback
            ))

            self.resolvePrimaryUpstream(
                query,
                resolverConfiguration: resolverConfiguration,
                purpose: .smokeProbe,
                admittedAtEpoch: admittedAtEpoch,
                // A PROBE HAS NO CLIENT, so its credit is fenced on the runtime instead of on a
                // delivery — see `TierOneRungCreditTiming`. Read here for the same reason
                // `admittedAtEpoch` is: this is still dnsStateQueue, before the probe hops.
                rungCreditTiming: .noClient(
                    admittedAtRuntimeGeneration: admittedAtRuntimeGeneration)
            ) { [weak self] primaryResult in
                guard let self else {
                    timeout.cancel()
                    finish()
                    return
                }

                // A lifecycle refusal ENDS the probe; it is not an ordinary primary failure.
                // The epoch fences the orchestrator, but this callback owns a SECOND egress
                // decision — the direct `resolveDeviceDNS` below — which consults only
                // `permitsPhysicalInterfaceDNS()`. So a probe admitted in session A, refused
                // for being stale, would still have had its canary sent on the wire during a
                // DNS-only session B with device fallback configured: the epoch would have
                // fenced everything except the one query it was supposed to stop (Codex P1,
                // PR #524). Nothing is reported either — the probe belongs to no session's
                // health ladder, exactly as its result says.
                // pinned: TunnelDataPathLatchSourceTests.testTheOrchestratorAdmitsWorkOnlyForTheLiveLifecycle
                // THE CAUSE IS DERIVED, not asserted. This branch used to be reachable only by a
                // lifecycle refusal, so a constant said everything. It now also catches a probe
                // fenced by a same-lifecycle RELATCH, and logging that as "lifecycle-ended" sends
                // whoever reads the capture looking for a tunnel restart that never happened —
                // erasing the distinction `.refusedAfterLatchReplaced` was added to draw
                // (Codex P2, PR #610).
                let terminalRefusal = primaryResult.attempts
                    .last { $0.outcome.endsTheResolutionLadder }?.outcome
                guard terminalRefusal == nil
                else {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-abandoned", details: [
                        "reason": reason,
                        "cause": terminalRefusal?.rawValue ?? "lifecycle-ended"
                    ])
                    timeout.cancel()
                    finish()
                    return
                }

                let primarySucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse(
                    primaryResult.response,
                    matching: query
                )

                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-primary-result", details: [
                    "reason": reason,
                    "primaryAccepted": "\(primarySucceeded)",
                    "primaryHasResponse": "\(primaryResult.response != nil)",
                    "primaryOutcome": primaryResult.failureSummary ?? "success",
                    "transport": primaryResult.transport.rawValue,
                    "resolver": primaryResult.successfulResolverAddress ?? primaryResult.attempts.last?.address ?? "nil"
                ])

                guard !primarySucceeded, canUseDeviceDNSFallback else {
                    timeout.cancel()
                    self.dnsStateQueue.async { [weak self] in
                        self?.completeResolverSmokeProbeResult(
                            token: probeStart.token,
                            reason: reason,
                            primaryResult: primaryResult,
                            primarySucceeded: primarySucceeded,
                            fallbackResult: nil,
                            fallbackSucceeded: false
                        )
                    }
                    finish()
                    return
                }

                self.resolverQueue.async { [weak self] in
                    guard let self else {
                        timeout.cancel()
                        finish()
                        return
                    }

                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-fallback-begin", details: [
                        "reason": reason,
                        "resolverCount": "\(resolverConfiguration.deviceDNSFallbackAddresses.count)"
                    ])

                    // A canary that reaches the resolver by leaking is worse than one that
                    // fails: it reports the tunnel healthy at the exact moment it is not
                    // carrying DNS, and the query it sent is the leak it was checking for.
                    //
                    // COMPLETED, not abandoned. Returning here left the timeout armed, so it
                    // fired seconds later and reported a synthetic probe FAILURE — a
                    // deliberate policy decision feeding the health model and the recovery
                    // ladder as though the resolver had misbehaved. That is the same
                    // neutrality this slice established for a refused resolution, broken by
                    // the guard that was meant to enforce it.
                    //
                    // The recorded fallback carries `refusedByEgressPolicy`, so what reaches
                    // health scoring says "declined" rather than "failed" or "never ran".
                    guard self.permitsPhysicalInterfaceDNS() else {
                        timeout.cancel()
                        let declined = DNSResolutionResult(
                            response: nil,
                            successfulResolverAddress: nil,
                            attempts: [
                                ResolverAttempt(
                                    address: resolverConfiguration.deviceDNSFallbackAddresses.first
                                        ?? "device-dns",
                                    outcome: .refusedByEgressPolicy,
                                    transport: .deviceDNS)
                            ],
                            transport: .deviceDNS,
                            udpTruncated: false,
                            tcpFallbackAttempted: false,
                            tcpFallbackSucceeded: false)
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel",
                            event: "dns-smoke-probe-fallback-refused",
                            details: ["reason": reason, "cause": "chained-egress-policy"])
                        self.dnsStateQueue.async { [weak self] in
                            self?.completeResolverSmokeProbeResult(
                                token: probeStart.token,
                                reason: reason,
                                primaryResult: primaryResult,
                                primarySucceeded: primarySucceeded,
                                fallbackResult: declined,
                                fallbackSucceeded: false
                            )
                        }
                        finish()
                        return
                    }
                    // The probe's SECOND egress decision, and the only guard on it was
                    // `permitsPhysicalInterfaceDNS()` — which asks whether the LATCH allows
                    // physical-interface DNS, not whether a session is still running. So a
                    // probe whose primary was ended by teardown fell straight through to a
                    // device-DNS query on the physical interface after the tunnel was gone.
                    //
                    // Quiescing the transports made that sharper rather than causing it: the
                    // cancelled lane now fails IMMEDIATELY instead of after its timeout, so
                    // the stale QUIC work is replaced by a prompt physical DNS query — and if
                    // it races the next start, charged to that measurement window (Codex P1,
                    // PR #522). Nothing is reported: a probe whose session ended belongs to
                    // no health ladder.
                    //
                    // The ADMITTING epoch, not the activity bit: this block reaches here on
                    // `resolverQueue`, an async hop after the primary's callback, and a
                    // stop/start can complete in that gap — a NEW session then satisfies
                    // "is there a session at all" and A's canary egresses during B's
                    // measurement window (Codex P1, PR #524). The probe may proceed only
                    // under the session that ADMITTED it; the same rule guards the socket
                    // seam below, so what this closes is the decision, not just the wire.
                    // pinned: TunnelDataPathLatchSourceTests.testTheProbesOwnFallbackIsGatedOnTheAdmittingLifecycle
                    guard ResolverOrchestrator.workIsAdmitted(
                        snapshot: admittedAtEpoch, live: self.currentResolverAdmissionEpoch()
                    ) else {
                        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-abandoned", details: [
                            "reason": reason,
                            "cause": "lifecycle-ended"
                        ])
                        timeout.cancel()
                        finish()
                        return
                    }

                    // `.providerDefault`, and stated rather than defaulted (PR #592). This is
                    // the SMOKE PROBE's device fallback, not the T1 rung: it belongs to the
                    // DNS-only health ladder, its egress question is already answered by the
                    // `permitsPhysicalInterfaceDNS()` guard above, and it has always followed
                    // the provider's own mode. Only the rung asks for `.physical`.
                    let fallbackResult = self.resolveDeviceDNS(
                        query,
                        resolverAddresses: resolverConfiguration.deviceDNSFallbackAddresses,
                        admittedAtEpoch: admittedAtEpoch,
                        egressInterface: .providerDefault, tier: .tierTwo,
                        replyContextIdentity: admittedAtTierContext,
                        replyRuntimeGeneration: admittedAtRuntimeGeneration
                    )
                    let fallbackEvidence = self.recordResolverTierReply(ResolverTierEvidence(
                        tier: .tierTwo, resolverKind: .device, egress: .physical,
                        result: fallbackResult, originatingLifecycle: admittedAtEpoch,
                        originatingLatchEpoch: nil), contextIdentity: admittedAtTierContext,
                        runtimeGeneration: admittedAtRuntimeGeneration)
                    let observedFallbackResult = fallbackResult.appendingTierEvidence(fallbackEvidence)
                    let fallbackSucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse(
                        fallbackResult.response,
                        matching: query
                    )

                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-fallback-result", details: [
                        "reason": reason,
                        "fallbackAccepted": "\(fallbackSucceeded)",
                        "fallbackHasResponse": "\(fallbackResult.response != nil)",
                        "fallbackOutcome": fallbackResult.failureSummary ?? "success",
                        "resolver": fallbackResult.successfulResolverAddress ?? fallbackResult.attempts.last?.address ?? "nil"
                    ])

                    timeout.cancel()
                    self.dnsStateQueue.async { [weak self] in
                        self?.completeResolverSmokeProbeResult(
                            token: probeStart.token,
                            reason: reason,
                            primaryResult: primaryResult,
                            primarySucceeded: primarySucceeded,
                            fallbackResult: observedFallbackResult,
                            fallbackSucceeded: fallbackSucceeded
                        )
                    }
                    finish()
                }
            }
        }
    }

    private func resolverSmokeProbeTimeoutResult(
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> DNSResolutionResult {
        DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(
                    address: resolverConfiguration.cacheIdentifier,
                    outcome: .timeout,
                    transport: resolverConfiguration.transport
                )
            ],
            transport: resolverConfiguration.transport,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false
        )
    }

    private func completeResolverSmokeProbeResult(
        token: ResolverSmokeProbeToken,
        reason: String,
        primaryResult: DNSResolutionResult,
        primarySucceeded: Bool,
        fallbackResult: DNSResolutionResult?,
        fallbackSucceeded: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        let occurredAt = Date()
        let completion = ResolverHealthSmokeProbeCompletion(
            occurredAt: occurredAt,
            reason: reason,
            primaryResult: primaryResult,
            primaryAccepted: primarySucceeded,
            fallbackResult: fallbackResult,
            fallbackAccepted: fallbackSucceeded,
            modeInsensitivePrimaryIdentifier:
                currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true).primaryCacheIdentifier,
            configuredResolverDisplayName:
                currentAppConfiguration().resolverPreset.displayName
        )
        let snapshot = health
        guard let transition = resolverHealthCoordinator.assumeIsolated({
            $0.completeSmokeProbe(
                completion,
                token: token,
                projectingOnto: snapshot
            )
        }) else {
            return
        }
        // Existing permitted probes can confirm the same Device tier. Only real stamped
        // transport results contribute; the outer synthetic timeout carries no tier evidence.
        // A probe has no client, so even a valid answer is liveness without service credit.
        let tierEvidence = (primaryResult.tierEvidence + (fallbackResult?.tierEvidence ?? []))
            .map { $0.recordingClientDeadlineExpired() }
        recordResolverTierEvidence(tierEvidence, at: occurredAt)
        applyResolverHealthTransition(transition)
    }

    func applyResolverHealthEvent(
        _ event: ResolverHealthGatewayEvent,
        hooks: ResolverHealthEffectHooks = ResolverHealthEffectHooks()
    ) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        let snapshot = health
        let transition = resolverHealthCoordinator.assumeIsolated {
            $0.apply(event, projectingOnto: snapshot)
        }
        applyResolverHealthTransition(transition, hooks: hooks)
    }

    private func applyResolverHealthTransition(
        _ transition: ResolverHealthCoordinatorTransition,
        hooks: ResolverHealthEffectHooks = ResolverHealthEffectHooks()
    ) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        transition.projection.apply(to: &health)
        executeResolverHealthEffects(transition.effects, hooks: hooks)
    }

    func currentResolverHealthSchedulingView() -> ResolverHealthSchedulingView {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return resolverHealthCoordinator.assumeIsolated { $0.schedulingView }
        }

        return dnsStateQueue.sync {
            resolverHealthCoordinator.assumeIsolated { $0.schedulingView }
        }
    }

    private func executeResolverHealthEffects(
        _ effects: [ResolverHealthGatewayEffect],
        hooks: ResolverHealthEffectHooks
    ) {
        var pendingResponses: [PendingDNSResponse] = []
        var pendingResolverIdentifier: String?

        for effect in effects {
            switch effect {
            case .persistHealth(let urgency):
                markResolverHealthProjectionUpdated()
                if urgency == .immediate {
                    persistHealthIfNeeded(force: true)
                }

            case .evaluateProtectionNotification(let occurredAt):
                hooks.beforeProtectionNotification?()
                scheduleProtectionNotificationIfNeeded(now: occurredAt)

            case .evaluateQAConnectivityLog(let reason, let occurredAt):
                #if LAVA_QA_TOOLS
                logQAConnectivityAssessmentIfNeeded(reason: reason, now: occurredAt)
                #endif

            case .appendNetworkActivity(let event, let occurredAt):
                appendNetworkActivity(event: event, now: occurredAt)

            case .recordEncryptedFallbackCarry(let carry):
                recordEncryptedFallbackCarry(carry)

            case .endEncryptedFallbackLogEpisode(let end):
                switch end {
                case .episodeEnd:
                    clearEncryptedFallbackLogThrottle()
                case .contextReset:
                    clearEncryptedFallbackLogThrottle(phase: "context-reset")
                }

            case .cancelFallbackRecoveryProbe:
                cancelFallbackRecoverySmokeProbe()

            case .cancelWedgeRecoveryProbe:
                cancelResolverWedgeRecoveryProbe()

            case .requestResolverRuntimeReset(let request):
                hooks.beforeResolverRuntimeReset?()
                switch request {
                case .full(let reason, let force):
                    let resolverIdentifier =
                        currentResolverRuntimeConfiguration().cacheIdentifier
                    pendingResponses = collectPendingResponsesAndResetResolverRuntime(
                        identifier: resolverIdentifier,
                        reason: reason,
                        force: force
                    )
                    pendingResolverIdentifier = resolverIdentifier
                }
                hooks.afterResolverRuntimeReset?()

            case .deliverPendingResolverFailures(let reason):
                guard let pendingResolverIdentifier else {
                    assertionFailure("Pending resolver failures had no preceding runtime reset")
                    continue
                }
                hooks.beforePendingResolverFailures?(
                    pendingResponses,
                    reason,
                    pendingResolverIdentifier
                )
                writeServerFailures(for: pendingResponses, reason: reason)

            case .clearDeviceDNSRecaptureRestartPending:
                // Compatibility effect: scoped tier evidence now owns recapture admission.
                break
            case .signalConnectivityProjectionChanged:
                signalAppIfConnectivityStateChanged()

            case .resetResolverBackoff(let reason):
                // task #56: SATISFIED chained roam whose tunnelled carry survives — the destructive
                // runtime reset was skipped to keep in-flight USER queries alive, so run here the reset's
                // beneficial stale-path cleanups that a surviving roam still needs, WITHOUT draining or
                // SERVFAILing those queries. Three things, all discarding evidence tied to the OLD path:
                //
                // (1) Clear the backoff penalty box so a resolver backed off on the degrading old link
                //     gets an immediate wire attempt on the healthy new path (INV-QUEUE-1:
                //     resolverBackoffPolicy is confined to resolverBackoffStateQueue).
                // (2) Advance the backoff-path epoch FIRST so any forward already in flight on the old
                //     path is tagged stale: on completion it writes its answer but cannot re-stamp the
                //     ledger we are about to clear (Codex P1, #565 — without a generation bump the
                //     completion would otherwise pass `completeForward`'s gate and record its timeout).
                // (3) Retire the in-flight smoke-probe token: the skipped reset's
                //     `beforeResolverRuntimeReset` hook would have called this, so without it a pre-roam
                //     probe's OLD-path failure completes after this transition zeroed the new episode's
                //     counters and repopulates failure/rejection evidence — a false reconnect/notification
                //     for the healthy new path (Codex P2, #565). Smoke probes are proactive, not user
                //     queries, so retiring the token just schedules a fresh probe.
                //
                // This executor runs on dnsStateQueue, so the epoch bump and smoke-probe token
                // invalidation are confined exactly like the full reset's generation bump.
                resolverBackoffPathEpoch += 1
                resetResolverTierEvidence()
                resolverBackoffStateQueue.sync {
                    resolverBackoffPolicy.reset()
                }
                invalidateInFlightSmokeProbes()
                LavaSecDeviceDebugLog.append(
                    component: "tunnel",
                    event: "resolver-backoff-cleared",
                    details: ["reason": reason]
                )

            case .recordIncident(let incident):
                Self.recordIncident(
                    incident.kind,
                    reason: incident.reason,
                    durationMs: incident.durationMilliseconds,
                    verifiedBy: incident.verifiedBy,
                    now: incident.occurredAt
                )

            case .deviceLog(let event):
                appendResolverHealthDeviceLog(event)

            case .reportConnectivityRecovery(let recovery):
                reportResolverConnectivityRecovery(recovery)

            case .creditProductiveSelfReconnect(let occurredAt):
                creditProductiveSelfReconnectIfPending(now: occurredAt)

            case .evaluateSelfReconnect(let occurredAt):
                let assessment = ProtectionConnectivityPolicy.assessment(
                    isConnected: true,
                    health: health,
                    now: occurredAt
                )
                selfReconnectIfPolicyAllows(assessment: assessment, now: occurredAt)

            case .scheduleFallbackRecoveryProbe:
                scheduleFallbackRecoverySmokeProbeIfNeeded()

            case .scheduleWedgeRecoveryProbe:
                scheduleResolverWedgeRecoveryProbeIfNeeded()
            }
        }
    }

    private func recordEncryptedFallbackCarry(
        _ carry: ResolverHealthGatewayEncryptedFallbackCarry
    ) {
        encryptedFallbackCarriedSinceLastLog += 1
        let dueForFallbackLog = lastEncryptedFallbackLogAt.map {
            carry.occurredAt.timeIntervalSince($0) >= encryptedFallbackLogThrottleInterval
        } ?? true
        if dueForFallbackLog {
            LavaSecDeviceDebugLog.append(
                component: "tunnel",
                event: "dns-encrypted-fallback",
                details: [
                    "transport": carry.transport.rawValue,
                    "resolver": carry.resolverAddress ?? "nil",
                    "carriedSinceLastLog": "\(encryptedFallbackCarriedSinceLastLog)",
                ]
            )
            lastEncryptedFallbackLogAt = carry.occurredAt
            encryptedFallbackCarriedSinceLastLog = 0
        }
    }

    private func appendResolverHealthDeviceLog(
        _ event: ResolverHealthGatewayDeviceLogEvent
    ) {
        switch event {
        case .smokeProbeSucceeded(
            let reason,
            let transport,
            let resolverAddress,
            let dohHTTPVersion,
            _
        ):
            LavaSecDeviceDebugLog.append(
                component: "tunnel",
                event: "dns-smoke-probe-success",
                details: [
                    "reason": reason,
                    "transport": transport.rawValue,
                    "resolver": resolverAddress ?? "nil",
                    "dohHTTPVersion": dohHTTPVersion ?? "nil",
                ]
            )

        case .smokeProbeDeviceFallback(
            let reason,
            let evidenceCount,
            let fallbackModeActive,
            let resolverAddress,
            _
        ):
            LavaSecDeviceDebugLog.append(
                component: "tunnel",
                event: "dns-smoke-probe-device-fallback",
                details: [
                    "reason": reason,
                    "evidenceCount": "\(evidenceCount)",
                    "fallbackModeActive": "\(fallbackModeActive)",
                    "resolver": resolverAddress ?? "nil",
                ]
            )

        case .smokeProbeFailed(
            let reason,
            let failure,
            let consecutiveSmokeFailures,
            let consecutiveRejectedResponses,
            _
        ):
            LavaSecDeviceDebugLog.append(
                component: "tunnel",
                event: "dns-smoke-probe-failed",
                details: [
                    "reason": reason,
                    "failure": failure,
                    "consecutiveSmokeFailures": "\(consecutiveSmokeFailures)",
                    "consecutiveRejectedResponses": "\(consecutiveRejectedResponses)",
                ]
            )
        }
    }

    private func reportResolverConnectivityRecovery(
        _ recovery: ResolverHealthGatewayRecovery
    ) {
        appendNetworkActivity(
            event: .connectivityRecovered(
                reason: "\(recovery.reason) via \(recovery.transport.rawValue)"
            ),
            now: recovery.recoveredAt,
            frozenHealthContext: recovery.activityContext
        )
        LavaSecDeviceDebugLog.append(
            component: "tunnel",
            event: "dns-recovered",
            details: [
                "reason": recovery.reason,
                "transport": recovery.transport.rawValue,
                "verifiedBy": recovery.verifiedBy,
                "durationMs": "\(recovery.durationMilliseconds)",
                "consecutiveUpstreamFailureCount":
                    "\(recovery.peakUpstreamFailureCount)",
            ]
        )
        Self.recordIncident(
            .wedgeRecovered,
            reason: recovery.reason,
            durationMs: recovery.durationMilliseconds,
            verifiedBy: recovery.verifiedBy,
            now: recovery.recoveredAt
        )
        lastSelfReconnectSuppressionSignature = nil
        lastSelfReconnectSuppressionLogAt = nil
        lastSelfReconnectPathSkipLogAt = nil
    }
}
