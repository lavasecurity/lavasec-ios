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
    // MARK: - Fallback recovery & wedge recovery probes

    func scheduleFallbackRecoverySmokeProbeIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleFallbackRecoverySmokeProbeIfNeeded()
            }
            return
        }

        guard tunnelLifecycleIsActive else {
            return
        }

        // Never armed while chained (C3). The ladder this follows up is itself suspended,
        // so fallback mode cannot legitimately be active — but that inertness was a
        // CONSEQUENCE of refusals scoring `declinedByPolicy`, which a health-scoring change
        // could quietly undo. Stated here as a decision instead, with the scheduler's own
        // guard as the backstop.
        // pinned: TunnelDataPathLatchSourceTests.testTheProbeTimersAreNotArmedWhileChained
        guard permitsPhysicalInterfaceDNS() else { return }

        let schedulingView = currentResolverHealthSchedulingView()
        guard DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: schedulingView.deviceDNSFallbackModeActive,
                consecutiveFallbackEvidenceCount: schedulingView.deviceDNSFallbackEvidenceCount
              ),
              schedulingView.networkPathIsSatisfied,
              fallbackRecoverySmokeProbeWorkItem == nil
        else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.fallbackRecoverySmokeProbeWorkItem = nil
            let schedulingView = self.currentResolverHealthSchedulingView()
            guard DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: schedulingView.deviceDNSFallbackModeActive,
                consecutiveFallbackEvidenceCount: schedulingView.deviceDNSFallbackEvidenceCount
            ) else {
                return
            }

            self.scheduleResolverSmokeProbeIfNeeded(reason: "device-dns-fallback-recovery")
        }

        fallbackRecoverySmokeProbeWorkItem = workItem
        dnsStateQueue.asyncAfter(
            deadline: .now() + DeviceDNSFallbackPolicy.fallbackRecoverySmokeProbeInterval,
            execute: workItem
        )
    }

    func cancelFallbackRecoverySmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelFallbackRecoverySmokeProbe()
            }
            return
        }

        fallbackRecoverySmokeProbeWorkItem?.cancel()
        fallbackRecoverySmokeProbeWorkItem = nil
    }

    // Same-network DNS wedge recovery. When every resolver address is benched
    // (e.g. a transient burst of timeouts under heavy browsing backs them all
    // off) with no network or resolver-runtime change, nothing resets that
    // penalty box: queries stay failed-closed until the per-address backoff
    // expires AND organic traffic happens to retry, or the 300s routine probe
    // runs, or the user toggles protection (a fresh process starts with an empty
    // backoff — which is why a manual toggle recovers when in-place retries do
    // not). Self-reconnect is the heavier escalation, but it is rate-limited and
    // requires confirmed Connect-On-Demand, so it is suppressed exactly when the
    // user is most stuck. This lighter recovery resets the resolver backoff +
    // stale upstream connections and re-probes on a short cadence, with no
    // process restart and no per-query hammering (one re-probe per interval).
    // Cancelled by the ordered resolver-health recovery effect as soon as DNS recovers.
    func scheduleResolverWedgeRecoveryProbeIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleResolverWedgeRecoveryProbeIfNeeded()
            }
            return
        }

        // Never armed while chained (C3) — and since the S6 carry this guard is
        // FIRST-LINE, not belt-and-braces. Wedge evidence used to be unproducible while
        // chained (probes suppressed, every organic resolution refused); tunnelled
        // timeouts now legitimately classify `.totalFailure` and emit
        // `.scheduleWedgeRecoveryProbe` on any chained DNS outage spanning the
        // three-failure threshold, so this guard is the one thing keeping the probe's
        // state churn (device-resolver re-read, backoff reset, transport session churn)
        // off the physical interface while chained. The sibling action on that effects
        // list, `.evaluateSelfReconnect`, has its own stand-down gate at
        // `selfReconnectIfPolicyAllows` for the same reason.
        // pinned: TunnelDataPathLatchSourceTests.testTheProbeTimersAreNotArmedWhileChained
        guard permitsPhysicalInterfaceDNS() else { return }

        guard currentResolverHealthSchedulingView().networkPathIsSatisfied else {
            return
        }

        // Decide the cadence mode + the delay up front so the already-armed check can compare
        // deadlines: the fast escalation (LAV-92) is for the UNCOVERED down-wedge (user offline now
        // → re-probe fast, ~2s doubling to the legacy 30s ceiling). A COVERED wedge (encrypted
        // fallback is carrying DNS; only the stale primary needs recapture) leaves the user online,
        // so it uses the gentle ceiling cadence AND holds the ramp counter at zero so a later real
        // down-wedge still starts fast.
        let now = Date()
        let coveredNow = ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: health, now: now)
        if coveredNow {
            resolverWedgeRecoveryAttempt = 0
        }
        let delay: TimeInterval
        if coveredNow {
            delay = resolverWedgeRecoveryCadence.maxInterval
        } else {
            // Floor the fast ramp at the recovery probe's ACTUAL smoke-probe timeout, computed the
            // SAME way the probe computes it (transport + device-DNS-fallback availability). A probe
            // that can hang to its timeout — an encrypted primary OR a fallback-capable plain
            // primary that runs primary-then-fallback — must not be re-armed sooner, or the new
            // probe supersedes the actor-owned smoke token mid-flight, discards the stale result,
            // and churns the session before it can recover. Since every re-arm
            // happens at-or-after the wedge fired and delay >= that timeout, the next probe never
            // fires before the in-flight one completes. A fast local probe (recovery timeout) still
            // effectively gets the short ramp.
            let rampDelay = resolverWedgeRecoveryCadence.delay(forAttempt: resolverWedgeRecoveryAttempt)
            let probeResolverConfiguration = currentResolverRuntimeConfiguration(
                ignoresDeviceDNSFallbackMode: true,
                allowsQueryFallback: false
            )
            let canUseDeviceDNSFallback = currentAppConfiguration().fallbackToDeviceDNS
                && probeResolverConfiguration.transport != .deviceDNS
                && !probeResolverConfiguration.deviceDNSFallbackAddresses.isEmpty
            let probeTimeout = TimeInterval(Self.smokeProbeTimeoutSeconds(
                reason: "resolver-wedge-recovery",
                transport: probeResolverConfiguration.transport,
                canUseDeviceDNSFallback: canUseDeviceDNSFallback
            ))
            delay = max(rampDelay, probeTimeout)
        }
        let deadline = now.addingTimeInterval(delay)

        if let armedDeadline = resolverWedgeRecoveryArmedDeadline {
            // A probe is already armed. Keep it UNLESS:
            //  * the cadence MODE changed (covered<->uncovered) — re-arm on the correct cadence for
            //    the new state: coverage lapsing speeds an offline user up to the fast ramp, and
            //    coverage engaging slows an online user back to the gentle cadence so a fast probe
            //    can't tear down a fallback that's keeping DNS working; OR
            //  * within the same mode, a strictly-sooner probe is now warranted.
            // An equal/later same-mode deadline keeps the pending probe, so repeated calls never
            // churn it.
            let modeChanged = resolverWedgeRecoveryArmedCovered != coveredNow
            guard modeChanged || deadline < armedDeadline else {
                return
            }
            resolverWedgeRecoveryWorkItem?.cancel()
            resolverWedgeRecoveryWorkItem = nil
            resolverWedgeRecoveryArmedDeadline = nil
        }

        // Committing to arm: count this uncovered probe toward the escalating ramp.
        if !coveredNow {
            resolverWedgeRecoveryAttempt += 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.resolverWedgeRecoveryWorkItem = nil
            // The armed probe has fired; clear its deadline so the loop's re-arm (via the
            // smoke-probe-failure path) isn't blocked by a now-past deadline.
            self.resolverWedgeRecoveryArmedDeadline = nil

            // Re-confirm the primary is still wedged before disrupting the runtime.
            // THREE independent signals can mean "primary still wedged"; honour ANY:
            //   * the assessment derived from `health` says `.reconnect` (DNS down), OR
            //   * the coordinator's reconnect episode (via currentDeviceResolverWedged)
            //     is still held — the masked-healthy DOWN wedge: a fallback-carried success
            //     clears health's failure counters so the assessment reads healthy, but the
            //     organic encrypted-fallback evidence preserves the marker, OR
            //   * the assessment says `.usingEncryptedFallback` — the COVERED wedge, where
            //     DoH/DoT is actively carrying DNS for a transition-stale Device-DNS primary.
            //     This signal is derived purely from `health` (the fallback serving timestamp
            //     + smoke state) and NEVER starts a reconnect episode, so it does not flip
            //     `treatsResolverRejectionAsFallbackTrigger` or bypass authoritative
            //     SERVFAIL/REFUSED — the exact reason recovery-in-place could not reuse the
            //     marker. It accelerates recapture from the routine cadence to this one.
            // A genuine recovery or lifecycle reset clears every signal (and cancels this
            // work item), so this still no-ops on an actually-healthy tunnel.
            let now = Date()
            let assessment = ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: self.health,
                now: now
            )
            let isDownWedge = assessment.primaryAction == .reconnect || self.currentDeviceResolverWedged()
            // Read the covered-coverage bit from the explicit named predicate rather than
            // string-matching the full assessment's severity — same source of truth, no re-derivation.
            // isCoveredWedge (rejection-gated) still drives the recapture REASON + the churn-skip;
            // isCarryingFallback (= covering MINUS the rejected==0 gate, but still requires a failed
            // smoke-probe context) keeps the loop ALIVE so a covered recapture probe that gets
            // rejected doesn't stall the cadence (the marker is unstamped). It does NOT fire for a
            // one-off fallback-carried query with no failed probe.
            let isCoveredWedge = ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: self.health, now: now)
            let isCarryingFallback = ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: self.health, now: now)
            let schedulingView = self.currentResolverHealthSchedulingView()
            guard schedulingView.networkPathIsSatisfied, isDownWedge || isCarryingFallback else {
                // The wedge cleared without a logged recovery cancelling us (e.g. a covered episode
                // whose coverage lapsed to a non-reconnect state, or a config/identity change reset
                // the runtime). End the episode so a later wedge restarts the fast ramp rather than
                // inheriting this episode's backed-off delay.
                self.resolverWedgeRecoveryAttempt = 0
                return
            }

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "resolver-wedge-recovery", details: [
                "reason": self.health.lastFailureReason ?? "dns-wedged",
                "severity": assessment.severity.diagnosticLabel,
                "mode": isCoveredWedge ? "encrypted-fallback-covered" : "down-wedge",
                "consecutiveUpstreamFailureCount": "\(self.health.consecutiveUpstreamFailureCount)"
            ])

            // Re-read the device resolvers (the transition-stale primary's addresses may
            // have changed on the new network; best-effort — in-tunnel capture was observed
            // empty in the 1758 log, the dedicated capture-retry is the real refresh) and
            // clear the backoff penalty box so the re-probe — and organic queries — get a
            // fresh attempt at the primary. The smoke probe honours backoff (the orchestrator
            // gates EVERY purpose on it), so without this reset a backed-off primary would
            // never be re-tested and could never recapture.
            self.refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "resolver-wedge-recovery")
            self.resolverBackoffStateQueue.sync {
                self.resolverBackoffPolicy.reset()
            }
            // Churn the encrypted transports' sessions ONLY for a DNS-DOWN wedge that the
            // encrypted fallback is NOT currently carrying. In the COVERED state — including
            // the OVERLAP where a stale DOWN-wedge marker was stamped (an uncovered `.reconnect`
            // moment) before coverage engaged and has not yet been cleared — those very DoH/DoT
            // sessions are actively serving DNS, so resetting them would disrupt the fallback
            // keeping the user online; a Device-DNS primary recapture does not need it (its
            // refresh is the device-DNS re-read above; the smoke re-probe below detects
            // recapture). `isCoveredWedge` tracks the fallback actively serving, so it suppresses
            // the churn even while the marker is still held. Once coverage genuinely lapses the
            // next pass (now !isCoveredWedge) takes the clean-slate reset.
            if isDownWedge, !isCoveredWedge {
                self.resetResolverTransientState()
            }
            // A failed re-probe re-arms this recovery through the reducer's held-marker
            // or encrypted-fallback-carrying evidence, so the loop
            // self-sustains at the wedge cadence until the primary recaptures (the success
            // path cancels it).
            self.scheduleResolverSmokeProbeIfNeeded(reason: isCoveredWedge ? "covered-primary-recapture" : "resolver-wedge-recovery")
        }

        resolverWedgeRecoveryWorkItem = workItem
        resolverWedgeRecoveryArmedDeadline = deadline
        resolverWedgeRecoveryArmedCovered = coveredNow
        dnsStateQueue.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    func cancelResolverWedgeRecoveryProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelResolverWedgeRecoveryProbe()
            }
            return
        }

        resolverWedgeRecoveryWorkItem?.cancel()
        resolverWedgeRecoveryWorkItem = nil
        resolverWedgeRecoveryArmedDeadline = nil
        // End of the wedge episode — the next one restarts the fast escalation ramp.
        resolverWedgeRecoveryAttempt = 0
    }
}
