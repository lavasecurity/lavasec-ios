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
    // MARK: - Device-DNS capture

    // SINGLE-SHOT device-DNS capture (was dns-recovery optimization C's bounded retry;
    // owner-directed Occam 2026-09-20, lavasec-infra plans/2026-09-17-path-independent-dns-
    // capture-floor.md P1). The in-tunnel capture comes back empty while our NEDNSSettings
    // own DNS (iOS masks the underlay resolvers behind the tunnel's own 10.255.0.1), and
    // the mask is deterministic for as long as the tunnel is up — a retry can only re-read
    // the same masked answer. So a scheduled capture reads ONCE: a non-empty capture is
    // adopted (and the runtime reset if the addresses changed); a masked/empty capture
    // falls straight through to the exhaustion side effects and does NOT re-arm. Only runs
    // when the active config actually depends on Device DNS (primary or fallback) and the
    // path is satisfied; superseded on the next handoff/wake/lifecycle reset. Exhaustion
    // PRESERVES the captured addresses (UR-55 / INV-DNS-5 — masked reads carry no handoff
    // evidence) and fires a policy-gated verification probe of the preserved primary,
    // leaving the wedge-recovery probe + on-demand-gated self-reconnect as the backstops,
    // which are unchanged.

    func scheduleDeviceDNSCaptureRetryIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleDeviceDNSCaptureRetryIfNeeded(reason: reason)
            }
            return
        }

        cancelDeviceDNSCaptureRetry()

        guard currentResolverHealthSchedulingView().networkPathIsSatisfied,
              currentConfigurationDependsOnDeviceDNS()
        else {
            return
        }

        // A wake alone is not evidence the mask lifted: the one-shot wake re-read
        // (refreshDeviceDNSResolverAddressesOnDNSQueue) already samples the current
        // network each wake, so scheduling another capture within the cooldown of an
        // exhausted-still-masked cycle only repeats a read that just failed. Any
        // non-wake reason means a real change — clear the cooldown and capture.
        // Synchronous isolated access: this method is dnsStateQueue-confined (hop guard
        // above), which IS the cycle actor's executor — assumeIsolated traps on a wrong
        // queue where the old dispatchPrecondition merely asserted in debug. The log
        // append and the arm run OUTSIDE isolation: they strictly follow the decision,
        // nothing interleaves with the cycle state.
        let decision = deviceDNSCaptureRetryCycle.assumeIsolated { cycle in
            cycle.noteScheduleRequest(isWake: reason == "wake")
        }
        switch decision {
        case .suppress(let logOnce):
            if logOnce {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-capture-retry-suppressed", details: [
                    "reason": reason
                ])
            }
            return
        case .start:
            armDeviceDNSCaptureRetry(reason: reason)
        }
    }

    private func armDeviceDNSCaptureRetry(reason: String) {
        // Reached only from dnsStateQueue-confined code (the schedule entry's hop guard,
        // or a capture delivered on dnsStateQueue by the cycle's scheduleAfter), which
        // IS the cycle actor's executor — synchronous assumeIsolated, zero hops.
        deviceDNSCaptureRetryCycle.assumeIsolated { cycle in
            cycle.armAttempt(
                after: DeviceDNSFallbackPolicy.deviceDNSCaptureRetryInterval
            ) { [weak self] in
                self?.runDeviceDNSCaptureRetry(reason: reason)
            }
        }
    }

    private func runDeviceDNSCaptureRetry(reason: String) {
        // The network or resolver config may have moved on since this was armed
        // (each handoff/wake supersedes via scheduleDeviceDNSCaptureRetryIfNeeded);
        // re-confirm before disturbing the runtime.
        guard currentResolverHealthSchedulingView().networkPathIsSatisfied,
              currentConfigurationDependsOnDeviceDNS()
        else {
            return
        }

        // One isolated region for the whole attempt: the cycle transitions
        // (noteCaptureSucceeded / noteExhausted) are data-dependently interleaved with
        // the capture work between them (the C-shim read feeds the outcome call, the
        // stale-drop computation feeds the exhaustion log), so the provider work cannot
        // move outside without reordering it. This body already runs on dnsStateQueue by
        // construction (armAttempt's scheduleAfter delivers there), which IS the cycle
        // actor's executor — the capture work is exactly as queue-confined as it was
        // pre-actor, and assumeIsolated now checks that instead of a comment
        // (INV-QUEUE-1). There is no re-arm: a masked read IS the exhaustion (SINGLE-SHOT).
        deviceDNSCaptureRetryCycle.assumeIsolated { cycle in
            let previousAddresses = deviceDNSResolverAddresses
            let read = Self.readSystemDNSServerAddresses()
            let captured = read.usable
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: captured,
                preserveOnEmptyCapture: true
            )

            // THE `masked` TERM IS THE POINT OF THIS LINE. `capturedCount: 0` alone cannot
            // say whether the network stopped answering or whether we simply read our own
            // listener back (the 2026-08-27 train captures logged that figure on every
            // read). The exhaustion below already explains that masking is EXPECTED in
            // steady state; this is what lets a reader confirm it rather than take it on
            // faith.
            var details = [
                "reason": reason,
                "capturedCount": "\(captured.count)",
                "activeCount": "\(deviceDNSResolverAddresses.count)"
            ]
            if captured.isEmpty {
                details["raw"] = "\(read.rawCount)"
                details["masked"] = "\(read.isMaskedBySelf)"
            }
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "device-dns-capture-retry", details: details)

            if !captured.isEmpty {
                // The mask lifted: we have this network's resolvers. If they actually
                // changed, reset the resolver runtime so in-flight + future queries use
                // them (mirrors the settle path) and fire a confirming smoke probe; a
                // genuine recovery then clears the wedge marker. The capture is no
                // longer masked, so the single shot is done.
                cycle.noteCaptureSucceeded(
                    addressesChanged: deviceDNSResolverAddresses != previousAddresses
                )
                if deviceDNSResolverAddresses != previousAddresses {
                    let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
                    let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
                        identifier: resolverIdentifier,
                        reason: "device-dns-recaptured-on-retry",
                        force: true
                    )
                    writeServerFailures(for: pendingResponses, reason: "device-dns-recaptured-on-retry")
                    scheduleResolverSmokeProbeIfNeeded(reason: "device-dns-recaptured-on-retry")
                }
                return
            }

            // SINGLE-SHOT (P1, owner-directed Occam 2026-09-20): the capture stayed masked.
            // With iOS masking the underlay resolvers while our NEDNSSettings own DNS
            // (Phase 0, lavasec-infra plans/2026-06-21-network-handoff-device-dns-recapture-
            // plan.md), a retry can only re-read the same masked answer — the rc6 field log
            // showed ~920 retries / 184 exhaustions per 6 h with zero recoveries. So the one
            // read IS the exhaustion: fall straight through to the side effects with no
            // re-arm. A masked read is NOT evidence of a resolver-changing handoff: the
            // in-process read is masked in STEADY STATE while the tunnel owns device DNS, so
            // on such a network EVERY armed cycle exhausts, including wake-armed cycles on a
            // perfectly stable Wi-Fi. 1.2.1 inferred a handoff here and dropped the captured
            // (still working) resolver whenever an encrypted fallback would catch the
            // queries; on a stable network that discarded a WORKING resolver and stranded
            // the user on the fallback until the next tunnel start, because the empty list
            // also blinded the recovery probes (UR-55).
            //
            // UR-55 rule (plans/2026-07-11-ur-55-device-dns-fallback-under-tunnel-plan.md):
            // the captured addresses are never mutated at exhaustion (INV-DNS-5). The
            // discriminator is a wire probe of the preserved primary — success keeps it in
            // service; failure lands wedge/health evidence (recovery cadences + the
            // rejection trigger). The probe deliberately does NOT write the live backoff
            // map: a false-negative probe benching a WORKING primary is the same
            // weak-evidence failure class this branch exists to remove.
            // pinned: PacketTunnelDNSRuntimeSourceTests.testSmokeProbesDoNotMutateLiveResolverBackoff
            // The bench instead comes from the FIRST organic failures via recordUpstreamResult:
            // after a real handoff each preserved address costs one fallback-carried query
            // the dead-primary wait (~1s UDP, +2s TCP on timeout) before ResolverBackoffPolicy
            // benches it on that single failure (30s, refreshed by later failures) and
            // subsequent queries take the fast `backed-off` skip. That bounded first-query
            // cost — the user stays online throughout; the per-query encrypted fallback
            // answers under INV-DNS-1's fail-closed/LKG rules — is the price of reversibility
            // versus the old drop's instant-but-stranding `deviceDNSUnavailable` (PR #342
            // review). The covered-primary-recapture loop keeps re-probing so traffic RETURNS
            // the moment the resolver answers again, and the next unmasked capture (tunnel
            // start) adopts a genuinely-new network's resolver. The probe is policy-gated so
            // equivalent evidence — fresh accepted-primary proof (NRG-3a mirror) or an
            // already-confirmed chronic failure streak inside its backoff spacing (UR-48 rc9
            // drain class) — skips the radio wake.
            // pinned: PacketTunnelDNSRuntimeSourceTests.testDeviceDNSCaptureExhaustionPreservesResolversAndVerifiesByProbe
            let routesToEncryptedFallback = currentResolverRuntimeConfiguration().encryptedFallback != nil
            cycle.noteExhausted()

            let schedulingView = currentResolverHealthSchedulingView()
            let verification = DeviceDNSFallbackPolicy.exhaustionVerificationDecision(
                lastAcceptedPrimaryEvidenceAt: schedulingView.lastAcceptedPrimaryEvidenceAt,
                consecutiveSmokeProbeFailures: schedulingView.consecutiveSmokeProbeFailureCount,
                lastWireSmokeProbeAt: lastWireSmokeProbeAt,
                now: Date()
            )
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-capture-retry-exhausted", details: [
                "reason": reason,
                "routesToEncryptedFallback": "\(routesToEncryptedFallback)",
                "verification": verification.rawValue
            ])
            Self.recordIncident(.deviceDNSRecaptureExhausted, reason: reason)

            if verification == .probe {
                scheduleResolverSmokeProbeIfNeeded(reason: "device-dns-exhaustion-verification")
            }

            // Capture exhaustion consults current Device tier evidence. Masking alone is
            // not a restart grant: its independent wire confirmation and shared budget
            // still apply (INV-DNS-4/5). A carrying encrypted fallback retains its existing
            // capture retry path; the no-fallback branch also arms the in-place wedge probe.
            // `currentResolverRuntimeConfiguration()` builds with allowsQueryFallback,
            // so `encryptedFallback != nil` is exactly the organic-query routing condition.
            if !routesToEncryptedFallback {
                promptDeviceDNSRecaptureRestartIfPolicyAllows(now: Date())
            }
        }
    }

    func cancelDeviceDNSCaptureRetry() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelDeviceDNSCaptureRetry()
            }
            return
        }

        deviceDNSCaptureRetryCycle.assumeIsolated { $0.cancelPendingAttempt() }
    }

    // True when live queries can route through Device DNS — either it is the
    // primary transport or it is the configured fallback — so a stale/masked
    // capture would wedge resolution and a re-capture is worth retrying. A pure
    // DoH/DoT/DoQ config with no device-DNS fallback never depends on the capture,
    // so the capture no-ops for it.
    private func currentConfigurationDependsOnDeviceDNS() -> Bool {
        let resolverConfiguration = currentResolverRuntimeConfiguration(
            ignoresDeviceDNSFallbackMode: true,
            allowsQueryFallback: false
        )
        return resolverConfiguration.transport == .deviceDNS
            || currentAppConfiguration().fallbackToDeviceDNS
    }
}
