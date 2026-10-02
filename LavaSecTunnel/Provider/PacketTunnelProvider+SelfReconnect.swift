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
    // MARK: - Self-reconnect & guarded teardown

    // Restart the tunnel to recover wedged DNS, rate-limited so a network that
    // simply can't resolve can't drive a restart loop. The restart kills this
    // process, so attempt history is persisted (in the app group) and read back on
    // the next launch for the cross-restart backoff. Only fires when protection is
    // enabled — Connect-On-Demand is what brings the tunnel back after the cancel.

    func selfReconnectIfPolicyAllows(assessment: ProtectionConnectivityAssessment, now: Date) {
        guard !hasRequestedSelfReconnect else {
            return
        }

        // THE PHYSICAL-PATH RECOVERY ACTOR STANDS DOWN WHILE CHAINED IS LATCHED (S6).
        // Before the tunnel-DNS carry, no organic evidence could reach the reconnect
        // machinery while chained — every resolution was refused and classified
        // `.declinedByPolicy` — so this funnel was unreachable by construction. The carry
        // makes tunnelled timeouts classify `.totalFailure("timeout")`, which crosses
        // `ProtectionConnectivityPolicy`'s three-failure threshold FASTER than the
        // driver's own `tunnelDNSUnservedThresholdSeconds` under active browsing, and an
        // ungated funnel would then tear the whole extension down mid-ladder: a second,
        // uncoordinated recovery actor racing the one the chained design appointed.
        // Chained health lives in `ChainedOutageDriver` — its ladder is bounded, its
        // surrender path persists a suppression and restarts deliberately — and a restart
        // from HERE resets that driver's per-lifecycle accounting while fixing nothing a
        // session rebuild would not. Gated at the funnel so both entries (the organic
        // effects path and the wedge-probe re-entry) are covered.
        // pinned: TunnelDataPathLatchSourceTests.testTheSelfReconnectActorStandsDownWhileChained
        guard dnsHealthAuthority().physicalReconnectMayAct else {
            let signature = "chained-latched"
            let changed = signature != lastSelfReconnectSuppressionSignature
            let cooldownElapsed = lastSelfReconnectSuppressionLogAt.map {
                now.timeIntervalSince($0) >= Self.selfReconnectSuppressionLogInterval
            } ?? true
            if changed || cooldownElapsed {
                lastSelfReconnectSuppressionSignature = signature
                lastSelfReconnectSuppressionLogAt = now
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "self-reconnect-suppressed",
                    details: ["reason": "chained-latched"])
            }
            return
        }

        // A fail-closed caused by an unavailable/unbuildable snapshot blocks all DNS, so
        // the smoke probe always fails — but restarting the extension cannot rebuild a
        // snapshot the config can't compile. Restarting would only flicker the VPN (the
        // exact loop that bricked Guard after a stale-pinned-hash refresh). Stay stable
        // fail-closed; recovery comes from the app re-publishing a buildable snapshot, not
        // a restart. (Runs on dnsStateQueue; the read takes snapshotQueue, a leaf lock that
        // never reaches back to dnsStateQueue, so the cross-queue read can't deadlock.)
        guard !isResidentFailClosedDueToUnavailableSnapshot() else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-suppressed-snapshot-unavailable", details: [
                "reason": health.lastFailureReason ?? "snapshot-unavailable"
            ])
            return
        }

        // Aggregate health cannot distinguish fixed-tier failure, local refusal and Device
        // silence. An enabled Device tier always defers to its confirmation owner; absent
        // eligible Device evidence deliberately withholds process cancellation (INV-DNS-4).
        // pinned: ResolverTierRecoverySourceTests.testLegacyDeviceRecoveryUsesTheSameConfirmation
        if hasConfiguredDeviceDNSTier {
            reconsiderDeviceDNSTierRecovery(now: now)
            return
        }

        let rawAttempts = Self.loadSelfReconnectAttemptTimes()
        // Normalize and self-heal the persisted store before deciding. prunedAttemptTimes
        // clamps future-dated entries (from a backward clock jump) to `now`; if we only
        // persisted on a reconnect, a future-dated entry would survive in defaults and
        // re-clamp to the advancing `now` on every evaluation, throttling self-reconnect
        // until wall time caught up to the bad timestamp. Persisting the normalized list
        // now rewrites the bad entry once so it ages out of the window normally.
        let attempts = TunnelSelfReconnectPolicy.prunedAttemptTimes(rawAttempts, now: now)
        if attempts != rawAttempts {
            Self.saveSelfReconnectAttemptTimes(attempts)
        }
        let restartReason: TunnelSelfReconnectPolicy.RestartReason = .wedge
        let protectionIsWanted = selfReconnectProtectionIsWanted()
        let decision = TunnelSelfReconnectPolicy.decision(
            assessment: assessment,
            protectionEnabled: protectionIsWanted,
            onDemandEnabled: Self.isOnDemandConfirmedEnabled(),
            recentReconnectTimes: attempts,
            reason: restartReason,
            lastCommittedReconnectAt: Self.loadLastCommittedSelfReconnectAt(now: now),
            now: now
        )
        guard decision == .reconnect else {
            // Surface *why* a wedge did not trigger a restart — the most common
            // "it said reconnect needed but never recovered" case. Un-gated and
            // privacy-safe (no queried domain is recorded), so Release/TestFlight
            // feedback reports carry the suppression reason. The lighter
            // wedge-recovery re-probe still runs regardless of this decision.
            //
            // A persistent wedge calls this on every failed query/tick, so dedup the
            // line: log only when the suppression signature changes or the cooldown
            // elapses, to keep one wedge from flooding (and evicting) the capped log.
            let reason = health.lastFailureReason ?? "dns-wedged"
            let signature = "\(decision)|\(restartReason)|\(reason)|\(protectionIsWanted)|\(Self.isOnDemandConfirmedEnabled())"
            let changed = signature != lastSelfReconnectSuppressionSignature
            let cooldownElapsed = lastSelfReconnectSuppressionLogAt.map {
                now.timeIntervalSince($0) >= Self.selfReconnectSuppressionLogInterval
            } ?? true
            if changed || cooldownElapsed {
                lastSelfReconnectSuppressionSignature = signature
                lastSelfReconnectSuppressionLogAt = now
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-suppressed", details: [
                    "decision": String(describing: decision),
                    "restartReason": "\(restartReason)",
                    "protectionEnabled": "\(protectionIsWanted)",
                    "onDemandConfirmed": "\(Self.isOnDemandConfirmedEnabled())",
                    "attemptsInWindow": "\(attempts.count)",
                    "reason": reason
                ])
            }
            return
        }

        lastSelfReconnectSuppressionSignature = nil
        lastSelfReconnectSuppressionLogAt = nil
        hasRequestedSelfReconnect = true

        performGuardedSelfReconnectTeardown(reason: restartReason, attempts: attempts, now: now)
    }

    // MARK: - Device DNS tier repair

    // Device repair belongs to its admitted tier even if another tier rescued the client.
    // A first failure owns one scoped confirmation; only its independent no-response result
    // grants cold recapture. Generic physical health probes still stand down while chained.
    // pinned: ResolverTierRecoverySourceTests.testRecaptureUsesTierEvidenceAndTheSharedBudget
    // One owned canary in the existing bounded resolver pool, only after current Device
    // traffic established a real no-response suspicion. It exercises that tier directly:
    // a working T0 or fixed T1 cannot short-circuit or confirm the Device repair.
    // pinned: ResolverTierRecoverySourceTests.testConfirmationUsesTheExistingBoundedDeviceExecutor
    func scheduleDeviceDNSTierConfirmation(evidence: ResolverTierEvidence, now: Date) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard !hasRequestedSelfReconnect, resolverTierConfirmation == nil,
              resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier),
              deviceDNSTierRecaptureIsEligible(evidence), selfReconnectProtectionIsWanted() else { return }

        let previousAddresses = deviceDNSResolverAddresses
        refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "tier-device-dns-failure")
        if deviceDNSResolverAddresses != previousAddresses {
            resetResolverTierEvidence()
            refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
            return
        }
        guard let context = resolverTierContextIdentity else { return }
        let generation = resolverRuntimeGeneration
        let token = UUID()
        let addresses = deviceDNSResolverAddresses.filter { !latchedChainedAllowedIPsCover($0) }
        guard !addresses.isEmpty else { return }
        let sequence = nextResolverTierObservationSequence()
        let query = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: DNSResolverSmokeProbe.probeDomain(forSequence: Int(truncatingIfNeeded: sequence)))
        resolverTierConfirmation = (token, evidence.tier, sequence)
        resolverTierHealth.setRecoveryStatus(.waiting, for: evidence.tier)
        logDeviceDNSTierConfirmation(evidence: evidence, decision: "checking", sequence: sequence)
        projectResolverTierHealth()

        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: Self.resolverQueryLifetimeSeconds)) { [weak self] in
            guard let self else { return false }
            let check = {
                self.resolverTierConfirmation?.id == token
                    && self.resolverTierContextIdentity == context
                    && self.currentResolverTierContextIdentity() == context
                    && self.resolverRuntimeGeneration == generation
                    && self.resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier)
                    && self.deviceDNSTierRecaptureIsEligible(evidence)
                    && self.selfReconnectProtectionIsWanted()
            }
            if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true { return check() }
            return self.dnsStateQueue.sync(execute: check)
        }
        let discard: @Sendable () -> Void = { [weak self] in
            self?.dnsStateQueue.async { [weak self] in
                guard let self, self.resolverTierConfirmation?.id == token else { return }
                self.resolverTierConfirmation = nil
                self.reconsiderDeviceDNSTierRecoveryAfterConfirmation(now: Date())
            }
        }
        runBoundedResolverWork(retainedBytes: query.count + 256, deadline: lifetime.deadline, discard: discard) { [weak self] finish in
            guard let self else { finish(); return }
            defer { finish() }
            guard lifetime.isAdmitted else { discard(); return }
            let result = self.resolveDeviceDNS(
                query, resolverAddresses: addresses, admittedAtEpoch: evidence.originatingLifecycle,
                admittedAtLatchEpoch: evidence.originatingLatchEpoch, egressInterface: .physical,
                lifetime: lifetime, tier: evidence.tier,
                replyContextIdentity: context, replyRuntimeGeneration: generation, livenessOnly: true)
            let rawObservation = ResolverTierEvidence(
                tier: evidence.tier, resolverKind: .device, egress: .physical,
                result: result, originatingLifecycle: evidence.originatingLifecycle,
                originatingLatchEpoch: evidence.originatingLatchEpoch)
                .recordingClientDeadlineExpired()
            let observation = self.recordResolverTierReply(
                rawObservation, contextIdentity: context, runtimeGeneration: generation)
            self.dnsStateQueue.async { [weak self] in
                guard let self, self.resolverTierConfirmation?.id == token else { return }
                self.resolverTierConfirmation = nil
                guard self.resolverTierContextIdentity == context,
                      self.currentResolverTierContextIdentity() == context,
                      self.resolverRuntimeGeneration == generation,
                      self.resolverTierEvidenceIsCurrent(observation) else {
                    self.reconsiderDeviceDNSTierRecoveryAfterConfirmation(now: Date())
                    return
                }
                self.logDeviceDNSTierConfirmation(
                    evidence: observation, decision: "completed", sequence: sequence)
                // A canary proves reachability, never delivered client service or restart credit.
                self.recordResolverTierEvidence([observation], at: Date())
                if self.resolverTierHealth.deviceDNSConfirmationNeeded(for: evidence.tier) {
                    self.reconsiderDeviceDNSTierRecoveryAfterConfirmation(now: Date())
                }
            }
        }
    }

    private func reconsiderDeviceDNSTierRecoveryAfterConfirmation(now: Date) {
        guard tunnelLifecycleIsActive, selfReconnectProtectionIsWanted(),
              DNSResolverTier.allCases.contains(where: { resolverTierHealth.deviceDNSConfirmationNeeded(for: $0) })
        else { return }
        let attempts = TunnelSelfReconnectPolicy.prunedAttemptTimes(Self.loadSelfReconnectAttemptTimes(), now: now)
        scheduleResolverTierRecaptureRetry(
            now: now, attempts: attempts,
            minimumDelay: TimeInterval(Self.udpDNSTimeoutSeconds + Self.tcpDNSTimeoutSeconds))
    }

    func logDeviceDNSTierConfirmation(evidence: ResolverTierEvidence, decision: String, sequence: UInt64) {
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-tier-confirmation", details: [
            "tier": evidence.tier.rawValue, "decision": decision, "sequence": "\(sequence)",
            "outcome": evidence.outcome.rawValue, "transport": evidence.transport.rawValue,
            "reason": evidence.failureReason?.rawValue ?? evidence.outcome.rawValue])
    }

    func evaluateDeviceDNSTierRecapture(
        evidence: ResolverTierEvidence, observationSequence: UInt64, now: Date
    ) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard let sendSequence = evidence.sendSequence,
              resolverTierHealth.deviceDNSRecaptureIsConfirmed(
                for: evidence.tier, sendSequence: sendSequence, observationSequence: observationSequence)
        else { return }
        guard deviceDNSTierRecaptureIsEligible(evidence) else {
            resolverTierHealth.setRecoveryStatus(.unavailable, for: evidence.tier)
            return
        }
        guard !hasRequestedSelfReconnect else { return }

        // A real in-place capture is cheaper than killing the extension. Masked reads retain
        // the old addresses (INV-DNS-5); only independent confirmed silence grants escalation
        // to cold capture. A new capture retires the old tier evidence immediately.
        let previousAddresses = deviceDNSResolverAddresses
        refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "tier-device-dns-failure")
        if deviceDNSResolverAddresses != previousAddresses {
            resetResolverTierEvidence()
            refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
            return
        }

        let attempts = TunnelSelfReconnectPolicy.prunedAttemptTimes(Self.loadSelfReconnectAttemptTimes(), now: now)
        Self.saveSelfReconnectAttemptTimes(attempts)
        let protectionIsWanted = selfReconnectProtectionIsWanted()
        let decision = TunnelSelfReconnectPolicy.decision(
            requirement: .deviceDNSRecapture,
            protectionEnabled: protectionIsWanted,
            onDemandEnabled: Self.isOnDemandConfirmedEnabled(),
            recentReconnectTimes: attempts,
            lastCommittedReconnectAt: Self.loadLastCommittedSelfReconnectAt(now: now),
            now: now)
        let status: DNSResolverTierHealthSnapshot.RecoveryStatus
        switch decision {
        case .reconnect: status = .eligible
        case .throttled: status = .throttled
        case .noAction: status = .unavailable
        }
        resolverTierHealth.setRecoveryStatus(status, for: evidence.tier)
        let signature = "\(evidence.tier.rawValue)|\(decision)|\(evidence.failureReason?.rawValue ?? "device-dns")|\(protectionIsWanted)"
        if lastResolverTierRecoveryLogSignature != signature {
            lastResolverTierRecoveryLogSignature = signature
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-tier-recovery", details: [
                "tier": evidence.tier.rawValue,
                "recoveryKind": "recaptureDeviceDNS",
                "decision": "\(decision)",
                "protectionEnabled": "\(protectionIsWanted)",
                "reason": evidence.failureReason?.rawValue ?? "device-dns",
                "attemptsInWindow": "\(attempts.count)"])
        }
        guard decision == .reconnect else {
            if decision == .throttled {
                scheduleResolverTierRecaptureRetry(now: now, attempts: attempts)
            }
            return
        }
        guard let contextIdentity = resolverTierContextIdentity else { return }
        let grant = DeviceDNSTierRecaptureGrant(
            evidence: evidence, contextIdentity: contextIdentity,
            runtimeGeneration: resolverRuntimeGeneration, observationSequence: observationSequence)
        hasRequestedSelfReconnect = true
        performGuardedSelfReconnectTeardown(
            reason: .deviceDNSRecapture, attempts: attempts, now: now, tierGrant: grant)
    }

    func deviceDNSTierRecaptureIsEligible(_ evidence: ResolverTierEvidence) -> Bool {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        let mode = currentTunnelDataPathMode()
        let physicalRungPermitted: Bool
        switch mode {
        case .dnsOnly:
            physicalRungPermitted = !protocolConfiguration.includeAllNetworks
        case .chainedUpstream(let upstream):
            physicalRungPermitted = !protocolConfiguration.includeAllNetworks && !upstream.containsFullTunnel
                && ChainedResolverEgressPolicy.permitsTierOneFallbackOnPhysicalInterface(
                    chainedIsLatched: true, routingPolicy: upstream.routingPolicy)
        }
        let context = ResolverTierEvidence.DeviceDNSRecaptureContext(
            lifecycle: tunnelLifecycleIsActive ? tunnelLifecycleGeneration : 0,
            latchEpoch: mode.isChainedUpstream ? tunnelDataPathLatchEpoch : nil,
            pathEpoch: resolverBackoffPathEpoch,
            physicalRungPermitted: physicalRungPermitted,
            networkPathSatisfied: latestMonitoredPathIsSatisfied
                && currentResolverHealthSchedulingView().networkPathIsSatisfied,
            snapshotAvailable: !isResidentFailClosedDueToUnavailableSnapshot(),
            currentDeviceDNSAddresses: deviceDNSResolverAddresses,
            profileCoveredAddresses: evidence.resolverAddresses.filter { latchedChainedAllowedIPsCover($0) })
        return evidence.permitsDeviceDNSRecapture(in: context)
    }

    func scheduleResolverTierRecaptureRetry(now: Date, attempts: [Date], minimumDelay: TimeInterval = 1) {
        guard resolverTierRecoveryRetry == nil, let context = resolverTierContextIdentity else { return }
        // One timer for the ladder, at the next shared-budget opportunity. Wake retires the
        // old grant and requests fresh confirmation; elapsed time is never failure evidence.
        var delay = minimumDelay
        let committed = Self.loadLastCommittedSelfReconnectAt(now: now)
        if let mostRecent = (attempts + (committed.map { [$0] } ?? [])).max() {
            delay = max(delay, TunnelSelfReconnectPolicy.cooldown - now.timeIntervalSince(mostRecent))
        }
        if attempts.count >= TunnelSelfReconnectPolicy.maxDeviceDNSRecaptureAttemptsPerWindow,
           let oldest = attempts.min() {
            delay = max(delay, TunnelSelfReconnectPolicy.attemptWindow - now.timeIntervalSince(oldest))
        }
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resolverTierRecoveryRetry = nil
            guard self.tunnelLifecycleIsActive,
                  self.resolverTierContextIdentity == context,
                  self.currentResolverTierContextIdentity() == context else { return }
            for tier in DNSResolverTier.allCases {
                if let evidence = self.latestResolverTierEvidence[tier],
                   evidence.resolverKind == .device, evidence.outcome == .failure {
                    self.resolverTierHealth.invalidateDeviceDNSConfirmation(
                        for: tier, observationSequence: self.nextResolverTierObservationSequence())
                    self.scheduleDeviceDNSTierConfirmation(evidence: evidence, now: Date())
                }
            }
            self.projectResolverTierHealth()
        }
        resolverTierRecoveryRetry = retry
        dnsStateQueue.asyncAfter(deadline: .now() + max(1, delay), execute: retry)
    }

    // Legacy capture exhaustion consults the same tier-owned evidence. A masked read,
    // idle traffic or an aggregate wedge cannot manufacture a Device restart grant.
    func promptDeviceDNSRecaptureRestartIfPolicyAllows(now: Date) {
        reconsiderDeviceDNSTierRecovery(now: now)
        scheduleResolverWedgeRecoveryProbeIfNeeded()
    }

    private var hasConfiguredDeviceDNSTier: Bool {
        currentAppConfiguration().dnsResolutionSelections.contains {
            $0.isEnabled && $0.resolver?.transport == .deviceDNS
        }
    }

    private func reconsiderDeviceDNSTierRecovery(now: Date) {
        for tier in DNSResolverTier.allCases {
            guard let evidence = latestResolverTierEvidence[tier],
                  evidence.resolverKind == .device, evidence.outcome == .failure else { continue }
            if let sequence = resolverTierHealth.deviceDNSRecaptureObservationSequence(for: tier) {
                evaluateDeviceDNSTierRecapture(evidence: evidence, observationSequence: sequence, now: now)
            } else if resolverTierHealth.deviceDNSConfirmationNeeded(for: tier) {
                scheduleDeviceDNSTierConfirmation(evidence: evidence, now: now)
            }
            if hasRequestedSelfReconnect { break }
        }
    }

    // Shared teardown for canonical Device confirmation and the existing non-Device wedge
    // owner. Revalidate the exact grant on a fresh DNS queue turn before committing a cancel.
    private func performGuardedSelfReconnectTeardown(
        reason: TunnelSelfReconnectPolicy.RestartReason,
        attempts: [Date],
        now: Date,
        tierGrant: DeviceDNSTierRecaptureGrant? = nil
    ) {
        // The decision and every `health` read above ran on dnsStateQueue, but the network
        // path can change before the teardown actually lands. A handoff that is still
        // settling flips the path to unsatisfied; cancelling then tears the tunnel down INTO
        // a dead network, where Connect-On-Demand has nothing to restart into — lengthening
        // the user-visible OFF window (field-confirmed 2026-06-22).
        //
        // Re-validate on a *fresh* dnsStateQueue turn, and gate on the freshest delivered
        // path state — `latestMonitoredPathIsSatisfied`, which the pathUpdateHandler stamps
        // synchronously. We deliberately do NOT rely on `health.networkPathIsSatisfied`
        // alone: handleNetworkPathUpdate applies that one via a SECOND deferred hop, so a
        // delivered-but-not-yet-applied path update would leave the cached flag
        // stale-satisfied and let the cancel through. Require BOTH.
        // On an unsatisfied path, release the latch and re-arm the lighter wedge-recovery
        // probe instead of cancelling blind — and do NOT burn a cap attempt for a teardown
        // that never ran (the cap-strand that otherwise compounds into a longer off).
        dnsStateQueue.async { [weak self] in
            guard let self, self.hasRequestedSelfReconnect, self.tunnelLifecycleIsActive else {
                return
            }
            // A queued smoke-probe or organic-query success can run on this queue between
            // the decision and this fresh turn, clearing the wedge WITHOUT clearing this
            // latch. Re-RUN THE FULL self-reconnect policy against fresh `health` (NOT just
            // `primaryAction == .reconnect`: a wedge cleared to `.dnsSlow` still reports
            // `.reconnect` while the policy is `.noAction`), threading the same
            // `reason` so the ceiling matches. Only commit + cancel while the policy STILL
            // says reconnect; otherwise release the latch and bail (recovery owns its probe).
            let revalidatedNow = Date()
            let currentAttempts = TunnelSelfReconnectPolicy.prunedAttemptTimes(
                Self.loadSelfReconnectAttemptTimes(), now: revalidatedNow)
            let protectionIsWanted = self.selfReconnectProtectionIsWanted()
            let revalidatedDecision: TunnelSelfReconnectPolicy.Decision
            if let tierGrant {
                guard self.resolverTierContextIdentity == tierGrant.contextIdentity,
                      self.currentResolverTierContextIdentity() == tierGrant.contextIdentity,
                      self.resolverRuntimeGeneration == tierGrant.runtimeGeneration,
                      self.latestResolverTierEvidence[tierGrant.evidence.tier]?.outcome == .failure,
                      let sendSequence = tierGrant.evidence.sendSequence,
                      self.resolverTierHealth.deviceDNSRecaptureIsConfirmed(
                        for: tierGrant.evidence.tier, sendSequence: sendSequence,
                        observationSequence: tierGrant.observationSequence),
                      self.deviceDNSTierRecaptureIsEligible(tierGrant.evidence) else {
                    self.hasRequestedSelfReconnect = false
                    if self.latestResolverTierEvidence[tierGrant.evidence.tier]?.outcome == .failure,
                       self.resolverTierHealth.deviceDNSConfirmationNeeded(for: tierGrant.evidence.tier)
                        || self.resolverTierHealth.deviceDNSRecaptureIsConfirmed(for: tierGrant.evidence.tier) {
                        self.resolverTierHealth.setRecoveryStatus(.waiting, for: tierGrant.evidence.tier)
                        self.projectResolverTierHealth()
                        self.scheduleResolverTierRecaptureRetry(now: revalidatedNow, attempts: currentAttempts)
                    }
                    return
                }
                revalidatedDecision = TunnelSelfReconnectPolicy.decision(
                    requirement: .deviceDNSRecapture,
                    protectionEnabled: protectionIsWanted,
                    onDemandEnabled: Self.isOnDemandConfirmedEnabled(),
                    recentReconnectTimes: currentAttempts,
                    lastCommittedReconnectAt: Self.loadLastCommittedSelfReconnectAt(now: revalidatedNow),
                    now: revalidatedNow)
            } else {
                // Configuration may have changed since the legacy decision. Device recovery
                // always returns to its typed confirmation owner, including on this final turn.
                if reason == .deviceDNSRecapture || self.hasConfiguredDeviceDNSTier {
                    self.hasRequestedSelfReconnect = false
                    self.reconsiderDeviceDNSTierRecovery(now: revalidatedNow)
                    return
                }
                // The legacy aggregate path still requires sustained wedge evidence.
                let assessment = ProtectionConnectivityPolicy.assessment(
                    isConnected: true, health: self.health, now: revalidatedNow)
                revalidatedDecision = TunnelSelfReconnectPolicy.decision(
                    assessment: assessment,
                    protectionEnabled: protectionIsWanted,
                    onDemandEnabled: Self.isOnDemandConfirmedEnabled(),
                    recentReconnectTimes: currentAttempts,
                    reason: reason,
                    lastCommittedReconnectAt: Self.loadLastCommittedSelfReconnectAt(now: revalidatedNow),
                    now: revalidatedNow)
            }
            guard revalidatedDecision == .reconnect else {
                self.hasRequestedSelfReconnect = false
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-suppressed", details: [
                    "decision": "\(revalidatedDecision)",
                    "restartReason": "\(reason)",
                    "protectionEnabled": "\(protectionIsWanted)",
                    "onDemandConfirmed": "\(Self.isOnDemandConfirmedEnabled())",
                    "attemptsInWindow": "\(currentAttempts.count)",
                    "reason": "final-admission"
                ])
                if let tierGrant {
                    self.resolverTierHealth.setRecoveryStatus(
                        revalidatedDecision == .throttled ? .throttled : .unavailable,
                        for: tierGrant.evidence.tier)
                    self.projectResolverTierHealth()
                    if revalidatedDecision == .throttled {
                        self.scheduleResolverTierRecaptureRetry(now: revalidatedNow, attempts: currentAttempts)
                    }
                }
                return
            }
            // Re-check the freshest delivered path AND health. The teardown is issued in THIS
            // same synchronous dnsStateQueue block — no main-queue hop — so the path cannot
            // flip between this guard and the cancel, and the persisted attempt is never
            // burned for a skipped teardown. cancelTunnelWithError is
            // async to iOS, and setTunnelNetworkSettings is already invoked off-main here, so
            // an off-main cancel is safe and keeps the path check + teardown atomic.
            let schedulingView = self.currentResolverHealthSchedulingView()
            guard self.latestMonitoredPathIsSatisfied, schedulingView.networkPathIsSatisfied else {
                self.hasRequestedSelfReconnect = false
                let cooldownElapsed = self.lastSelfReconnectPathSkipLogAt.map {
                    now.timeIntervalSince($0) >= Self.selfReconnectSuppressionLogInterval
                } ?? true
                if cooldownElapsed {
                    self.lastSelfReconnectPathSkipLogAt = now
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-skipped-path-unsatisfied", details: [
                        "reason": self.health.lastFailureReason ?? "dns-wedged"
                    ])
                }
                self.scheduleResolverWedgeRecoveryProbeIfNeeded()
                return
            }

            let updatedAttempts = currentAttempts + [revalidatedNow]
            Self.saveSelfReconnectAttemptTimes(updatedAttempts)
            LavaSecAppGroup.sharedDefaults.set(
                revalidatedNow.timeIntervalSince1970, forKey: "tunnel.lastCommittedSelfReconnectAt")
            // Persist a restart-survivable "a self-reconnect was committed at `now`" marker
            // BEFORE the cancel (which kills the process). The NEXT launch's first confirmed
            // primary recovery credits this attempt back (creditProductiveSelfReconnectIfPending),
            // so a productive restart nets ~0 against the cap while a true loop — which never
            // reaches a post-restart recovery — accrues to the ceiling. Must be persisted, NOT
            // tracked via the coordinator's in-memory reconnect episode, which the cancel
            // wipes (the relaunched process would never credit otherwise).
            Self.saveLastSelfReconnectAt(revalidatedNow)
            LavaSecAppGroup.sharedDefaults.set(
                reason == .deviceDNSRecapture, forKey: "tunnel.selfReconnectRequiresDeviceDNSCredit")
            if let tierGrant {
                self.resolverTierHealth.setRecoveryStatus(.restarting, for: tierGrant.evidence.tier)
                self.projectResolverTierHealth()
                self.persistHealthIfNeeded(force: true)
            }
            let committedReason = tierGrant?.evidence.failureReason?.rawValue
                ?? self.health.lastFailureReason ?? "dns-wedged"
            // Durable GAP evidence, decoupled from the rate-limiter's stores (which forget by
            // design: the credit deletes the recovered attempt, the marker above is one-shot,
            // the report prunes to the 600 s window). Start stamped here; the ended marker is
            // CLEARED so the pair can only ever describe THIS gap — the relaunched process
            // stamps it at startTunnel when it is serving again. Never read by
            // TunnelSelfReconnectPolicy, so the cap/cooldown inputs are untouched.
            Self.openSelfReconnectGap(at: revalidatedNow)
            // Ledger record BEFORE the cancel below kills the process (synchronous write —
            // the async hop would not survive cancelTunnelWithError; CON-1). Bounded by the
            // non-blocking lock, and at teardown there is no ongoing DNS to stall.
            Self.recordIncident(
                .selfReconnectCommitted,
                reason: committedReason,
                now: revalidatedNow,
                synchronous: true
            )

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect", details: [
                "reason": committedReason,
                "restartReason": "\(reason)",
                "protectionEnabled": "\(protectionIsWanted)",
                "attemptsInWindow": "\(updatedAttempts.count)"
            ])

            self.cancelTunnelWithError(nil)
        }
    }

    // Explicit OFF is persisted before the app's asynchronous disarm. Reading the
    // sidecar keeps a cached configuration ON from granting a restart during that wait.
    // Only absence preserves compatibility; missing storage and unavailable intent fail closed.
    // pinned: ResolverTierRecoverySourceTests.testAllSelfReconnectAdmissionsUseAuthoritativeIntentAndOnlyFreshLaunchCredits
    private func selfReconnectProtectionIsWanted() -> Bool {
        guard let container = LavaSecAppGroup.containerURL else { return false }
        return ProtectionRestoreIntentStore.read(containerURL: container)
            .resolvedIntent(fallingBackTo: currentAppConfiguration().protectionEnabled)
    }

    // Confirmed by the app only after `saveToPreferences` arms Connect-On-Demand.
    // Defaults to false (never armed) so a missing/failed-to-arm signal suppresses
    // self-reconnect rather than risking a cancel with no automatic recovery.
    static func isOnDemandConfirmedEnabled() -> Bool {
        LavaSecAppGroup.sharedDefaults.bool(
            forKey: LavaSecAppGroup.protectionOnDemandConfirmedEnabledDefaultsKeyName
        )
    }

    private static func loadSelfReconnectAttemptTimes() -> [Date] {
        let raw = LavaSecAppGroup.sharedDefaults.array(forKey: selfReconnectAttemptsDefaultsKeyName) as? [Double] ?? []
        return raw.map(Date.init(timeIntervalSince1970:))
    }

    private static func saveSelfReconnectAttemptTimes(_ times: [Date]) {
        LavaSecAppGroup.sharedDefaults.set(
            times.map(\.timeIntervalSince1970),
            forKey: selfReconnectAttemptsDefaultsKeyName
        )
    }

    // Productive credit reduces the window cap but never erases the last commit's cooldown.
    private static func loadLastCommittedSelfReconnectAt(now: Date = Date()) -> Date? {
        let key = "tunnel.lastCommittedSelfReconnectAt"
        let raw = LavaSecAppGroup.sharedDefaults.double(forKey: key)
        guard raw > 0 else { return nil }
        let normalized = min(Date(timeIntervalSince1970: raw), now)
        // Normalize the durable marker once after a backward clock jump. Re-clamping only
        // in policy would keep moving the cooldown forward on every evaluation.
        if normalized.timeIntervalSince1970 != raw {
            LavaSecAppGroup.sharedDefaults.set(normalized.timeIntervalSince1970, forKey: key)
        }
        return normalized
    }

    private static func loadLastSelfReconnectAt() -> Date? {
        let raw = LavaSecAppGroup.sharedDefaults.double(forKey: lastSelfReconnectAtDefaultsKeyName)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    static func launchFollowsRecentSelfReconnect(now: Date) -> Bool {
        guard let lastSelfReconnectAt = loadLastSelfReconnectAt() else {
            return false
        }

        let age = now.timeIntervalSince(lastSelfReconnectAt)
        return age >= 0 && age <= selfReconnectCreditWindow
    }

    private static func saveLastSelfReconnectAt(_ date: Date) {
        LavaSecAppGroup.sharedDefaults.set(date.timeIntervalSince1970, forKey: lastSelfReconnectAtDefaultsKeyName)
    }

    private static func clearLastSelfReconnectAt() {
        LavaSecAppGroup.sharedDefaults.removeObject(forKey: lastSelfReconnectAtDefaultsKeyName)
    }

    // CON-1: INCIDENT-LEDGER IO runs on this dedicated SERIAL queue, never dnsStateQueue —
    // so a cross-process flock a suspended app holds can never wedge DNS serving. Serial ⇒
    // append order is preserved. Static so the static `recordIncident` can use it too.
    //
    // The terminal self-reconnect commit drains this queue via `sync` before
    // cancelTunnelWithError (see `recordIncident`), so EVERYTHING enqueued here MUST use the
    // non-blocking bounded lock — append, sweepExpired, and the tunnel-side `tryClear`. A
    // blocking op here could wait indefinitely on a flock a suspended app holds, and the
    // teardown draining behind it would stall, recreating the very DNS outage this change
    // prevents (Codex #200 P2). NetworkActivity IO lives on its OWN queue below for exactly
    // this reason — its clear is BLOCKING and its flock is heavily app-contended, so it must
    // never share the queue the terminal `sync` drains.
    // TRANSPORT/PRESSURE DIAGNOSTIC APPENDS, off the data-path queues.
    //
    // `LavaSecDeviceDebugLog.append` formats JSON and does open/fstat/write/close
    // synchronously. The transport sink runs on the NWConnection queue and the pressure sink on
    // the packet producer's thread, so appending inline put filesystem latency directly in the
    // path of packet processing — precisely while the tunnel is waiting or backpressured, which
    // is when these events fire. That contradicts the observer's non-blocking sink contract and
    // could AMPLIFY the very brief stall the telemetry exists to observe (Codex P2, PR #581).
    //
    // Its OWN queue rather than `appGroupLogIOQueue`: that one is drained by a terminal `sync`
    // during self-reconnect teardown, so everything on it must use the non-blocking bounded
    // lock. Debug-log appends carry no such guarantee, and borrowing that queue would put an
    // unbounded flock wait in front of a teardown path. Serial, so emission order is preserved;
    // the recorder's own rate limit (one line per second per key) bounds what can pile up.
    static let transportDiagnosticsLogQueue = DispatchQueue(
        label: "com.lavasec.tunnel.transport-diagnostics-log", qos: .utility)

    static let appGroupLogIOQueue = DispatchQueue(label: "com.lavasec.tunnel.app-group-log-io", qos: .utility)

    // CON-1: NETWORK-ACTIVITY IO on its OWN serial queue, split from the incident ledger
    // (Codex #200 P2). Two independent files with no cross-file ordering requirement, so
    // splitting is safe and each queue still serializes its own file's append-vs-clear
    // (anti-resurrection). The split matters because the network-activity flock is heavily
    // cross-process contended — the app's blocking `append` and `loadPruned` both hold it —
    // so its clear stays BLOCKING/reliable (a user privacy wipe must not silently drop). That
    // is safe HERE because no terminal `sync` drains this queue: a blocked clear delays only
    // its own completion, never DNS serving or the self-reconnect teardown.
    static let networkActivityLogIOQueue = DispatchQueue(label: "com.lavasec.tunnel.network-activity-log-io", qos: .utility)

    // OBS R2: the append-only incident ledger. Observability-only, exactly like the gap
    // pair below: nothing in the recovery/cap policy reads the ledger, writes add no
    // control flow at their call sites, and the file lives outside the rate-limiter's
    // stores (which forget by design — productive credit, 600s prune, resetHealth), so a
    // late-filed report still carries the incident timeline.
    //
    // CON-1: the ledger append hops onto `appGroupLogIOQueue` (off dnsStateQueue) with a
    // non-blocking bounded lock, so it can never stall DNS. The terminal self-reconnect
    // commit sets the `synchronous` flag: it still runs ON `appGroupLogIOQueue` (so it keeps
    // append order behind any queued incidents), but via `sync` so it lands durably BEFORE
    // cancelTunnelWithError tears the process down. At teardown there is no ongoing DNS to
    // stall, and the drain is bounded by the non-blocking lock on each queued write.
    static func recordIncident(
        _ kind: IncidentLedgerRecord.Kind,
        reason: String? = nil,
        durationMs: Int? = nil,
        verifiedBy: String? = nil,
        now: Date = Date(),
        synchronous: Bool = false
    ) {
        // INV-PERSIST-1: a pre-unlock append reads the locked ledger as empty and atomically
        // saves a one-record file over the user's incident history — the same clobber class
        // the suite canary closes. Skipped while locked: observability-only (nothing in the
        // recovery policy reads the ledger), and the documented cost is one unrecorded
        // pre-unlock incident; the debug log still carries the event line.
        guard sharedProtectedContentIsReadableForObservabilityWriters() else {
            return
        }
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return
        }
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        let record = IncidentLedgerRecord(
            at: now,
            kind: kind,
            reason: reason,
            durationMs: durationMs,
            verifiedBy: verifiedBy
        )
        guard !synchronous else {
            // Terminal self-reconnect commit: still serialized on appGroupLogIOQueue, but
            // via `sync` (CON-1, Codex #200). `sync` drains every already-enqueued async
            // incident first — so the append-only timeline can't show the restart before
            // the incident that triggered it — then writes and RETURNS before
            // cancelTunnelWithError tears the process down (durable). Deadlock-safe: this
            // runs off the self-reconnect teardown queue, never appGroupLogIOQueue itself,
            // and IO-queue blocks never re-enter that queue.
            appGroupLogIOQueue.sync {
                IncidentLedgerPersistence.append(record, to: ledgerURL)
                // `append` returns Bool, so this trailing closure infers `() -> Bool` and Swift
                // resolves to DispatchQueue's generic `sync<T>` overload (T = Bool); the Bool it
                // returns is unused at the call site → "result of call to 'sync(execute:)' is
                // unused". The explicit Void return pins the closure to `() -> Void`, selecting the
                // non-generic `sync(execute:)`. (`append` is @discardableResult, so the inner call
                // itself never warns — that attribute does not affect this overload resolution.)
                return
            }
            return
        }
        appGroupLogIOQueue.async {
            IncidentLedgerPersistence.append(record, to: ledgerURL)
        }
    }

    // Startup retention sweep for the ledger file. The tunnel never reads ledger
    // CONTENTS (the frozen recovery path takes no input from it) — this call only
    // arms/confirms the two-phase expiry inside the persistence lock and discards
    // everything else. CON-1: hopped onto appGroupLogIOQueue with the non-blocking
    // bounded lock, so it never writes synchronously inside startTunnel /
    // loadInitialSharedState and can never stall the startup path on a held lock.
    static func sweepIncidentLedger() {
        // INV-PERSIST-1 (pinned: TunnelPreUnlockGuardSourceTests.testObservabilityWritersAreCanaryGated):
        // the sweep reads the ledger and rewrites it — a pre-unlock pass reads the locked
        // file as empty and would atomically save emptiness over the user's incident
        // history. Skipped while locked; the next sweep (each start / debounced pass) runs
        // post-unlock.
        guard sharedProtectedContentIsReadableForObservabilityWriters() else {
            return
        }
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return
        }
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        appGroupLogIOQueue.async {
            IncidentLedgerPersistence.sweepExpired(at: ledgerURL)
        }
    }

    // Durable self-reconnect gap pair (LAV-92/93 observability; keys documented in
    // LavaSecAppGroup). Observability-only: nothing in the recovery/cap policy reads these.
    private static func openSelfReconnectGap(at now: Date) {
        let defaults = LavaSecAppGroup.sharedDefaults
        // Clear the previous end BEFORE publishing the new start: the two writes are not
        // atomic across processes, and the reverse order lets a concurrent reader pair the
        // NEW start with the OLD end (a bogus zero/negative "closed" gap masking an open
        // outage). This order's worst interleave is the conservative one — the previous gap
        // briefly reads as still open. Readers additionally ignore any end that is not
        // AFTER the start they loaded, covering an extension killed between the writes.
        defaults.removeObject(forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKeyName)
        defaults.set(now.timeIntervalSince1970, forKey: LavaSecAppGroup.selfReconnectGapStartedAtDefaultsKeyName)
        defaults.set(
            defaults.integer(forKey: LavaSecAppGroup.selfReconnectGapCountDefaultsKeyName) + 1,
            forKey: LavaSecAppGroup.selfReconnectGapCountDefaultsKeyName
        )
    }

    // Closes the Guard-off window a committed self-reconnect opened. Called from the
    // startTunnel READY point (settings installed, packets flowing — fail-closed counts as
    // serving, no leak either way), never at entry: a failed settings install leaves the gap
    // open, which is the truth. If Connect-On-Demand never relaunched us and the user toggled
    // manually hours later, the long duration is exactly the honest signal (the LAV-92/93
    // residual).
    static func closeDanglingSelfReconnectGapIfNeeded(now: Date = Date()) {
        let defaults = LavaSecAppGroup.sharedDefaults
        let startedAtRaw = defaults.double(forKey: LavaSecAppGroup.selfReconnectGapStartedAtDefaultsKeyName)
        // A gap is genuinely closed only when its end is AFTER its start: an end at or
        // before the start is a stale leftover from the PREVIOUS gap (the extension can die
        // between the open's two writes), and skipping on it would leave the new gap
        // unclosed forever. Overwrite it with the honest close instead.
        let endedAtRaw = defaults.double(forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKeyName)
        guard startedAtRaw > 0, endedAtRaw <= startedAtRaw else {
            return
        }
        // COH-2: the reader accepts an end only if it is STRICTLY AFTER the start. A backward
        // wall-clock step larger than the relaunch latency makes `now <= startedAt`, so stamping
        // a raw `now` here writes `ended <= started` — which the app reader rejects as stale and
        // reads the gap as still OPEN forever (every bug report then flags an ongoing incident
        // while serving normally). Floor the end at `startedAt + 1s` so it reads as closed; this
        // is observability-only (the marker, never the reconnect decision) and self-heals the
        // moment the clock passes the recorded start.
        let nowRaw = now.timeIntervalSince1970
        let clockWentBackward = nowRaw <= startedAtRaw
        let endedRaw = clockWentBackward ? startedAtRaw + 1 : nowRaw
        defaults.set(endedRaw, forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKeyName)
        let gapMilliseconds = max(0, Int(((endedRaw - startedAtRaw) * 1_000).rounded()))
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-gap-closed", details: [
            "gapMs": "\(gapMilliseconds)",
            "clockAnomaly": "\(clockWentBackward)"
        ])
    }

    // Productive-recovery credit. Legacy primary smoke recovery and a deliverable organic
    // Device tier response consult the persisted one-shot marker. A Device-specific restart
    // accepts only the latter; a fixed alternative's recovery never erases its budget.
    // If a self-reconnect was committed before this launch (persisted
    // `lastSelfReconnectAt`) and we've now recovered within the credit window, that restart
    // was PRODUCTIVE: remove ONLY that restart's own attempt from the shared store, leaving
    // any earlier UNproductive attempts counted so the cap still bounds a restart-without-
    // recovery loop. Decoupled from the in-memory wedge marker on purpose — that
    // marker does not survive the cancel's process kill, so crediting through it would be a
    // no-op for the cold restart this serves.
    func creditProductiveSelfReconnectIfPending(now: Date, recoveredDeviceDNS: Bool = false) {
        // A fixed/T0 answer cannot credit a Device-DNS-specific recapture: otherwise a working
        // alternative erases every failed restart and defeats the shared loop cap (INV-DNS-4).
        if LavaSecAppGroup.sharedDefaults.bool(forKey: "tunnel.selfReconnectRequiresDeviceDNSCredit"),
           !recoveredDeviceDNS { return }
        guard let lastSelfReconnectAt = Self.loadLastSelfReconnectAt() else {
            return
        }
        // Cancellation reaches iOS asynchronously. An already queued reply in the
        // process being cancelled cannot prove the next launch recaptured working DNS.
        // Preserve the marker until a newer startup observes recovery; a clock regression
        // conservatively denies credit without erasing the shared attempt or cooldown.
        // pinned: ResolverTierRecoverySourceTests.testAllSelfReconnectAdmissionsUseAuthoritativeIntentAndOnlyFreshLaunchCredits
        guard health.startedAt > lastSelfReconnectAt else { return }
        // One-shot regardless of outcome: a stale marker must not keep crediting.
        Self.clearLastSelfReconnectAt()
        LavaSecAppGroup.sharedDefaults.removeObject(forKey: "tunnel.selfReconnectRequiresDeviceDNSCredit")
        guard now.timeIntervalSince(lastSelfReconnectAt) >= 0,
              now.timeIntervalSince(lastSelfReconnectAt) <= Self.selfReconnectCreditWindow else {
            return
        }
        // Remove a SINGLE matching attempt — the one stamped for the restart that recovered
        // (the marker and the persisted attempt are the same instant) — not every attempt at-
        // or-before it. Crediting all of them would erase earlier failures and let an
        // intermittent loop exceed the per-window cap after one success.
        var remaining = Self.loadSelfReconnectAttemptTimes()
        if let creditedIndex = remaining.firstIndex(of: lastSelfReconnectAt) {
            remaining.remove(at: creditedIndex)
        }
        Self.saveSelfReconnectAttemptTimes(remaining)
        // The credit DELETES the attempt from the policy store (correct for the cap) —
        // the ledger record is what survives to a late-filed report.
        Self.recordIncident(
            .selfReconnectCredited,
            durationMs: max(0, Int((now.timeIntervalSince(lastSelfReconnectAt) * 1_000).rounded())),
            now: now
        )
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-credited", details: [
            "recoveredAfterMs": "\(max(0, Int((now.timeIntervalSince(lastSelfReconnectAt) * 1_000).rounded())))",
            "attemptsRemaining": "\(remaining.count)"
        ])
    }

    #if LAVA_QA_TOOLS
    func logQAConnectivityAssessmentIfNeeded(reason: String, now: Date) {
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        let severity = assessment.severity
        let isProblem = severity == .needsReconnect
            || severity == .networkUnavailable
            || severity == .usingDeviceDNSFallback
            || severity == .usingEncryptedFallback
        let didChangeSeverity = severity != lastQAConnectivitySeverity
        let isThrottledProblemReminder = isProblem && now.timeIntervalSince(lastQAConnectivityLogAt) >= 300

        guard didChangeSeverity || isThrottledProblemReminder else {
            return
        }

        lastQAConnectivitySeverity = severity
        lastQAConnectivityLogAt = now

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "qa-connectivity-assessment", details: [
            "reason": reason,
            "severity": String(describing: severity),
            "primaryAction": String(describing: assessment.primaryAction),
            "networkKind": health.networkKind.rawValue,
            "networkPathIsSatisfied": "\(health.networkPathIsSatisfied)",
            "lastFailureReason": health.lastFailureReason ?? "nil",
            "lastResolverTransport": health.lastResolverTransport.rawValue,
            "upstreamSuccessCount": "\(health.upstreamSuccessCount)",
            "upstreamFailureCount": "\(health.upstreamFailureCount)",
            "consecutiveUpstreamFailureCount": "\(health.consecutiveUpstreamFailureCount)",
            "upstreamTimeoutCount": "\(health.upstreamTimeoutCount)",
            "dnsSmokeProbeSuccessCount": "\(health.dnsSmokeProbeSuccessCount)",
            "dnsSmokeProbeFailureCount": "\(health.dnsSmokeProbeFailureCount)",
            "lastDNSSmokeProbeSucceeded": health.lastDNSSmokeProbeSucceeded.map { "\($0)" } ?? "nil",
            "deviceDNSFallbackActivationCount": "\(health.deviceDNSFallbackActivationCount)",
            "deviceDNSFallbackModeActive": "\(currentDeviceDNSFallbackModeActive())",
            "resolverRuntimeResetCount": "\(health.resolverRuntimeResetCount)",
            "lastNetworkChangeAt": Self.qaDebugDateString(health.lastNetworkChangeAt),
            "lastResolverRuntimeResetAt": Self.qaDebugDateString(health.lastResolverRuntimeResetAt),
            "lastUpstreamSuccessAt": Self.qaDebugDateString(health.lastUpstreamSuccessAt),
            "lastUpstreamFailureAt": Self.qaDebugDateString(health.lastUpstreamFailureAt),
            "lastDNSSmokeProbeAt": Self.qaDebugDateString(health.lastDNSSmokeProbeAt)
        ])
    }

    private static func qaDebugDateString(_ date: Date?) -> String {
        guard let date else {
            return "nil"
        }

        return SharedDateFormatting.iso8601.string(from: date)
    }
    #endif

    func applyDiagnosticsControlIfNeeded(force: Bool = false) {
        guard let diagnosticsControlURL else {
            return
        }

        let modifiedAt = modificationDate(for: diagnosticsControlURL)
        guard force || modifiedAt != lastDiagnosticsControlModifiedAt else {
            return
        }

        lastDiagnosticsControlModifiedAt = modifiedAt
        let control = DiagnosticsControlPersistence.load(from: diagnosticsControlURL)
        var didApplyControl = false

        // Dedup against the DURABLE applied-marker on the store (PST-1): only apply a
        // control request strictly newer than the clear this store already carries, so a
        // force-apply on every start can't re-wipe data accumulated since the clear. The
        // clear methods stamp the marker to `requestedAt`, so the next start's gate is
        // `requestedAt > requestedAt` = false.
        if let requestedAt = control.clearDomainHistoryRequestedAt,
           requestedAt > (diagnostics.lastAppliedDomainHistoryClearAt ?? .distantPast) {
            diagnostics.clearDomainHistory(clearedAt: requestedAt)
            didApplyControl = true
        }

        if let requestedAt = control.clearFilteringCountsRequestedAt,
           requestedAt > (diagnostics.lastAppliedFilteringCountsClearAt ?? .distantPast) {
            diagnostics.clearFilteringCounts(startedAt: requestedAt)
            didApplyControl = true
        }

        if didApplyControl {
            markDiagnosticsUpdated()
        }
    }

    func markDiagnosticsUpdated() {
        diagnosticsPersistence.markDirty()
    }

    func persistDiagnosticsIfNeeded(force: Bool = false) {
        diagnosticsPersistence.flush(force: force)
    }

    // Loads — or at post-unlock recovery RELOADS — the diagnostics JSON store and the Domain
    // History depth store from the app group. A pre-unlock boot read the locked diagnostics
    // file as EMPTY, and serve-path markers (local-protection uptime, counts) then dirtied
    // that empty in-memory store; without this reload the post-unlock retry would save the
    // emptiness over the user's real counts/history (Codex P1 round 6 on #377 — the same
    // load-then-reload discipline the app side applies via
    // reloadSharedStateIfBlockedByDataProtection). The depth store equally reopens here: its
    // pre-unlock open failed and left dnsEventLog nil. Boot call site runs before
    // readPackets (nothing races the assignment); the recovery call site runs on
    // dnsStateQueue inside the deferred-begin flush, the same serialized queue the
    // diagnostics write closure runs on, so no persist can interleave the swap.
    // The pre-unlock in-memory counts discarded by the reload are the locked window's
    // transient bookkeeping — post-INV-PERSIST-2 those are real classifications, not just
    // fail-closed SERVFAILs, but the user's persisted history is what must win. The locked
    // window's filtering evidence is NOT lost with them: it survives in the health
    // snapshot's lockedBoot* counters (Class-None, never reloaded — see recordDiagnostic).
    func loadDiagnosticsAndEventLogStores() {
        // Record whether THIS load ran against a locked container. The diagnostics write
        // closure refuses to persist while the resident stores reflect a locked-empty boot,
        // INDEPENDENT of the session-begin lifecycle: tying the gate to the pending-begin
        // flag let a post-unlock stopTunnel — whose endProtectionVPNSession legitimately
        // drops that flag — unblock persisting the boot-empty store over the user's real
        // history (Codex P1 round 7 on #377). The flag clears only when a load runs with
        // the content readable (the deferred-begin flush's reload, or a normal boot);
        // unlock is monotonic until the next reboot, so a readable probe here cannot
        // regress before the reads below.
        diagnosticsStoresReflectLockedBoot = !sharedProtectedContentIsReadable()
        if diagnosticsStoresReflectLockedBoot {
            // Fresh locked observation (boot load): bounds the locked-boot evidence
            // window (see lastObservedLockedSharedContentAt).
            lastObservedLockedSharedContentAt = Date()
        }
        // The locked→readable window-end stamp deliberately does NOT live here: this
        // loader also runs OFF dnsStateQueue (loadInitialSharedState / startTunnel),
        // where a reused provider instance whose flag is still set from a locked
        // previous session would mutate health and the queue-confined health
        // persistence off-queue (INV-QUEUE-1) — and startTunnel's resetHealth wipes
        // the stamp moments later regardless. The transition is detected and stamped
        // at the deferred-begin flush, the only mid-session (on-queue) readable
        // reload (Codex review, #381).
        // pinned: TunnelPreUnlockGuardSourceTests.testLockedBootWindowEndStampIsForcePersistedAtTheReadableReload
        if let diagnosticsURL {
            diagnostics = DiagnosticsPersistence.load(from: diagnosticsURL)
        }

        // Open the Domain History depth store (best-effort) and, on first run, seed it from the
        // JSON events buffer so an upgrading install isn't briefly blank until fresh queries
        // accrue. Sole-writer opens read-write; the app opens the same file read-only.
        if let dnsEventLogURL {
            dnsEventLog = try? DNSEventLog(url: dnsEventLogURL)
            try? dnsEventLog?.seedIfEmpty(from: diagnostics.recentEvents)
        }

        applyDiagnosticsControlIfNeeded(force: true)
    }

    // Drains the DNS event log's buffered best-effort appends and, ONLY when the buffer
    // fully drained, prunes below the 7-day retention window and the app's clear floor.
    // The single primitive behind every drain site — the debounced diagnostics write, the
    // stop-path teardown, and sleep() — so no drain can ever land a buffered pre-clear
    // batch WITHOUT the prune that removes it running right after in the same pass. The
    // stop path is why the coupling must live here and not in the write closure alone: a
    // clear-contended closure pass skips its prune (and stays dirty), but the process is
    // exiting — if the teardown's own drain then succeeds, it would commit the retained
    // pre-clear rows with no later pass ever running (Codex P1, PR #351 round 4). A drain
    // that fails here is privacy-FAIL-SAFE: the uncommitted batch dies with the process
    // rather than being resurrected.
    // Runs on dnsStateQueue at every call site (the write closure's scheduler, the stop
    // teardown's async block, and sleep()'s async block), matching the log's established
    // cross-queue usage (INV-QUEUE-1: no new confinement shape).
    // Returns whether BOTH halves completed — a swallowed prune failure after a successful
    // drain (the clear writer can grab the lock BETWEEN the two) would report a pass as
    // complete with pre-clear rows freshly committed and unpruned, clearing the dirty flag
    // that guarantees the retry (Codex P2, PR #351 round 5). A false return leaves the
    // debounced controller dirty; at a terminal site the residual is bounded by the clear
    // floor persisting in shared defaults — the next tunnel session's first pass prunes
    // below it, and the app's read path hides the rows meanwhile.
    //
    // `discardOnFailure` is the terminal-vs-debounced split for the DRAIN half: a failed
    // flush() RETAINS its batch and arms an async retry on the log's own queue, which on a
    // terminal path can commit pre-clear rows in the teardown/pre-suspension window AFTER
    // this helper skipped the coupled prune — with no later pass ever running (Codex P2,
    // PR #351 round 7). Terminal callers (stop, sleep) pass true so a failed drain DROPS
    // the batch (the armed retry then no-ops on the empty buffer); the debounced caller
    // passes false and keeps retain-and-retry — in-session, its resurrected rows are
    // removed within one cadence by the dirty-retained re-run.
    // - pinned: PacketTunnelDNSRuntimeSourceTests.testDiagnosticsPersistenceFlushesBufferedDNSEventsBeforePruning
    @discardableResult
    func drainAndPruneDNSEventLog(now: Date = Date(), discardOnFailure: Bool) -> Bool {
        guard let dnsEventLog else {
            return true
        }
        let drained = discardOnFailure ? dnsEventLog.flushOrDiscard() : dnsEventLog.flush()
        guard drained else {
            return false
        }
        let retentionCutoff = now.addingTimeInterval(-LocalLogRetention.fineGrainedWindow)
        let clearFloorMs = LavaSecAppGroup.sharedDefaults.integer(forKey: LavaSecAppGroup.dnsEventLogClearedAtKeyName)
        let cutoff = clearFloorMs > 0
            ? max(retentionCutoff, Date(timeIntervalSince1970: Double(clearFloorMs) / 1000))
            : retentionCutoff
        do {
            try dnsEventLog.prune(before: cutoff)
        } catch {
            // Failure-only line (no per-event cost): a transient busy-timeout loss to the
            // app's clear writer self-heals via the controller's re-armed retry, but a
            // PERSISTENTLY failing prune (schema drift, disk corruption) would otherwise be
            // invisible in a field report while cleared rows stay stored (OCR P2,
            // lavasec-ios#54 sync review). Leak surface: none — LogError is a plain Swift
            // enum (no LocalizedError conformance), so the bridged localizedDescription is
            // the generic type-and-code form and never carries the associated SQL/errmsg
            // strings; and even those are parameterized statement text or engine messages,
            // never a domain. The structured sqliteCode below is what actually carries the
            // diagnosis.
            var details = Self.errorDebugDetails(error)
            if case let DNSEventLog.LogError.sql(_, code) = error {
                details["sqliteCode"] = "\(code)"
            } else if case let DNSEventLog.LogError.open(code) = error {
                details["sqliteCode"] = "\(code)"
            }
            LavaSecDeviceDebugLog.append(
                component: "tunnel",
                event: "dns-event-log-prune-failed",
                details: details
            )
            return false
        }
        return true
    }
}
