import Foundation

public enum DeviceDNSFallbackPolicy {
    public static let queryFallbackActivationThreshold = 3

    /// Whether a captured system-DNS address is a usable upstream resolver, by
    /// structure alone (the caller still rejects the tunnel's own listener address,
    /// which is config-specific). Rejects ranges that can never resolve real queries
    /// and only ever appear as half-configured/transient captures on a fresh link:
    /// unspecified, loopback, link-local (IPv4 `169.254/16`, IPv6 `fe80::/10`), and
    /// the IPv6 well-known NAT64 prefix (`64:ff9b::/96`). Adopting one wedges DNS on
    /// an address that cannot answer — the stale-resolver strand Phase 0 hygiene
    /// removes. Input is expected to be a canonical `inet_ntop` address; an
    /// unparseable string is treated as unusable.
    public static func isUsableResolverAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let octets = withUnsafeBytes(of: v4) { Array($0) } // network byte order == octet order
            return isUsableIPv4Octets(octets)
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) } // 16 bytes, network order
            if b.allSatisfy({ $0 == 0 }) {
                return false // :: unspecified
            }
            if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 {
                return false // ::1 loopback
            }
            if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 {
                return false // fe80::/10 link-local
            }
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
                // 64:ff9b::/96 well-known NAT64. An IPv6-only/NAT64 path can legitimately hand
                // out an IPv4 resolver reached through this prefix (e.g. 64:ff9b::8.8.8.8), and
                // it IS routable from inside the tunnel — the CLAT/464XLAT layer translates it
                // (Codex P2). So don't drop the prefix wholesale; judge it by its embedded IPv4
                // (the low 32 bits) so a NAT64-mapped public resolver is kept while a NAT64-mapped
                // loopback/link-local/unspecified (which still cannot answer) is rejected.
                return isUsableIPv4Octets(Array(b[12..<16]))
            }
            return true
        }

        return false // unparseable → not a usable resolver
    }

    /// Whether a 4-byte IPv4 address (network/octet order) can serve as an upstream
    /// resolver, rejecting only the ranges that can never answer real queries:
    /// `0.0.0.0/8` (unspecified), `127.0.0.0/8` (loopback), `169.254.0.0/16` (link-local).
    /// Shared by the IPv4 path and the embedded-IPv4 check of the NAT64 prefix.
    private static func isUsableIPv4Octets(_ octets: [UInt8]) -> Bool {
        switch octets[0] {
        case 0:
            return false // 0.0.0.0/8 ("this network" / unspecified)
        case 127:
            return false // 127.0.0.0/8 loopback
        case 169:
            return octets[1] != 254 // 169.254.0.0/16 link-local
        default:
            return true
        }
    }
    public static let routineSmokeProbeInterval: TimeInterval = 300
    public static let fallbackRecoverySmokeProbeInterval: TimeInterval = 30

    public static func nextConsecutiveFallbackEvidenceCount(
        currentCount: Int,
        primaryResolverWasAttempted: Bool
    ) -> Int {
        guard primaryResolverWasAttempted else {
            return currentCount
        }

        return min(currentCount + 1, queryFallbackActivationThreshold)
    }

    public static func shouldActivateFallbackMode(consecutiveQueryFallbackSuccesses: Int) -> Bool {
        consecutiveQueryFallbackSuccesses >= queryFallbackActivationThreshold
    }

    public static func shouldScheduleFallbackFollowUpProbe(
        deviceDNSFallbackModeActive: Bool,
        consecutiveFallbackEvidenceCount: Int
    ) -> Bool {
        deviceDNSFallbackModeActive || consecutiveFallbackEvidenceCount > 0
    }

    // preserveOnEmptyCapture is a stability heuristic — it stops a transient masked
    // read (iOS surfacing only Lava's tunnel DNS) from wiping working resolvers.
    // Its failure mode is the `send-failed` wedge: on a real handoff an empty read
    // PRESERVES the previous network's (now unreachable) resolvers. The bounded
    // capture-retry below (dns-recovery optimization C) narrows that hole by
    // re-reading until the capture comes back non-empty.
    public static func refreshedResolverAddresses(
        current: [String],
        captured: [String],
        preserveOnEmptyCapture: Bool = true
    ) -> [String] {
        guard captured.isEmpty else {
            return captured
        }

        return preserveOnEmptyCapture ? current : []
    }

    // dns-recovery optimization C — bounded device-DNS capture retry.
    //
    // preserveOnEmptyCapture (above) keeps working resolvers across a transient
    // masked read, but on a resolver-CHANGING handoff an empty read strands a
    // Device-DNS user on the previous network's unreachable resolvers — the silent
    // wedge UR-37 reported, where a tunnel restart was the only thing that
    // re-captured. The retry narrows that: after a handoff/wake, re-read the system
    // resolvers every `deviceDNSCaptureRetryInterval` for up to
    // `deviceDNSCaptureMaxRetryAttempts` tries until the capture is non-empty (then
    // the caller adopts it and stops). On networks/iOS versions where the mask
    // lifts a beat after the path settles this recovers in place with no restart;
    // on a fully-masked network it gives up after the cap and leaves the
    // wedge-recovery probe + (on-demand-gated) self-reconnect as the backstops.
    // Cost: a few extra reads during a transition.
    public static let deviceDNSCaptureRetryInterval: TimeInterval = 1
    public static let deviceDNSCaptureMaxRetryAttempts = 5

    /// Whether to schedule another bounded capture retry. Stops as soon as a
    /// non-empty capture is seen (the caller adopts the fresh addresses) or the
    /// attempt cap is reached. `attemptsMade` counts retries already performed
    /// (1-based: pass 1 after the first retry).
    public static func shouldRetryDeviceDNSCapture(
        attemptsMade: Int,
        capturedNonEmpty: Bool
    ) -> Bool {
        guard !capturedNonEmpty else {
            return false
        }

        return attemptsMade < deviceDNSCaptureMaxRetryAttempts
    }

    // On a chronically-masked network (in-tunnel capture ALWAYS reads empty), a
    // sleep/wake-thrashing device restarts the full retry cycle on every wake: the
    // UR-48 follow-up log shows a median 5 s wake cadence driving ~1,500 masked
    // reads (plus a debug-log append each) over ~4.7 h — 108 full exhaustions,
    // zero recoveries. A wake carries no evidence the mask lifted, and the wake
    // path's one-shot re-read still samples the network every wake, so after an
    // exhausted-still-masked cycle the burst retry is pure battery drain within
    // this cooldown. Network-path changes, tunnel starts, and fresh processes are
    // real change signals and bypass it (the caller clears the exhaustion stamp).
    public static let deviceDNSCaptureRetryExhaustionCooldown: TimeInterval = 60

    /// Whether a wake may restart the bounded capture-retry cycle. `nil` means no
    /// cycle has exhausted while masked since the last real change signal — always
    /// retry. A negative age (clock set backwards) fails open to retrying rather
    /// than suppressing on a bogus future stamp.
    public static func shouldRestartCaptureRetryCycleAfterWake(
        lastExhaustedMaskedCaptureAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastExhaustedMaskedCaptureAt else {
            return true
        }

        let age = now.timeIntervalSince(lastExhaustedMaskedCaptureAt)
        return age < 0 || age >= deviceDNSCaptureRetryExhaustionCooldown
    }

    // A sleep/wake-thrashing device (UR-48 rc9 follow-up log: 303 wakes in ~9.7 h,
    // median gaps of seconds) pays a full resolver teardown on EVERY wake — ~292
    // fresh DoH TLS handshakes + 270 encrypted-fallback context resets in that log,
    // tearing down the very sessions carrying DNS during micro-sleeps, plus a
    // SERVFAIL for every pending query. After a brief suspension the pre-sleep
    // connections are overwhelmingly still valid; the stale-socket risk the
    // teardown exists for grows with time asleep, not with the wake itself. Below
    // this threshold wake keeps the live runtime and leans on the existing safety
    // nets (the coalesced settle probe re-checks the resolver; wedge recovery and
    // handleNetworkPathUpdate's force reset catch a genuinely dead socket or a
    // real network change). 30 s is comfortably past the observed micro-sleep
    // cadence while short enough that DHCP/NAT rebinding across a longer sleep
    // still gets the conservative teardown.
    public static let briefWakeResolverPreserveThreshold: TimeInterval = 30

    /// Whether wake() may KEEP the live resolver runtime (DoH/DoT/DoQ sessions,
    /// response cache, pending queries) instead of force-resetting it. `nil`
    /// means the suspension start was never observed (fresh process, or an OS
    /// wake with no paired sleep) — tear down, the conservative default. A
    /// negative interval (clock set backwards across the sleep) also tears down
    /// rather than trusting a bogus future stamp.
    public static func shouldPreserveResolverRuntimeAcrossWake(
        sleepBeganAt: Date?,
        now: Date
    ) -> Bool {
        guard let sleepBeganAt else {
            return false
        }

        let sleptFor = now.timeIntervalSince(sleepBeganAt)
        return sleptFor >= 0 && sleptFor <= briefWakeResolverPreserveThreshold
    }

    // On a chronically-failing network the fixed routine cadence is pure radio drain:
    // the UR-48 rc9 log shows 533 failed wire probes vs 34 successes in ~9.7 h with
    // `consecutiveSmokeFailures` past 500 and no adaptive behavior. Failures beyond the
    // activation count stretch the ROUTINE cadence (doubling, capped at the ceiling);
    // every event-driven probe reason (wedge, fallback-recovery, settle, config-change,
    // startTunnel) stays unconditional, and the consecutive-failure counter this keys on
    // already resets on any probe success, recovery, and network-path change — so leaving
    // backoff is instant on every real change signal. Worst case is bounded: a network
    // that un-masks silently with NO path change, wake, or traffic evidence waits at most
    // the ceiling (vs the base cadence) to leave an already-working fallback.
    public static let smokeProbeBackoffActivationFailureCount = 5
    public static let maxRoutineSmokeProbeInterval: TimeInterval = 900

    /// Routine smoke-probe cadence given the current consecutive-failure streak: the base
    /// interval below the activation count (transient blips keep today's behavior exactly),
    /// then doubling per further failure up to the ceiling.
    public static func routineSmokeProbeInterval(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures >= smokeProbeBackoffActivationFailureCount else {
            return routineSmokeProbeInterval
        }

        // Cap the exponent well before the ceiling clamp so a persisted multi-hundred
        // streak can't overflow the multiplication.
        let doublings = min(failures - smokeProbeBackoffActivationFailureCount + 1, 8)
        return min(routineSmokeProbeInterval * pow(2.0, Double(doublings)), maxRoutineSmokeProbeInterval)
    }

    // Log/counter hygiene (UR-48 Phase 2a). The rc9 log's dominant line on a masked network
    // is `device-dns-captured count=0` (832 of 858 reads), and `consecutiveSmokeFailures`
    // climbed past 500 with nothing reading values that large — both pure noise in a
    // capped 5,000-line log that exists to diagnose incidents.

    /// Saturation point for the consecutive smoke-probe failure streak. Every consumer
    /// threshold (fallback activation, backoff activation, reconnect escalation) sits orders
    /// of magnitude below this, so saturating changes no behavior — it only stops a
    /// persisted health counter from growing without bound on a chronically-failing network.
    public static let maxTrackedConsecutiveSmokeProbeFailures = 999

    /// Next value of the consecutive-failure streak after one more failure (saturating).
    public static func nextConsecutiveSmokeProbeFailureCount(current: Int) -> Int {
        min(current + 1, maxTrackedConsecutiveSmokeProbeFailures)
    }

    /// Whether a device-DNS capture read is worth a log line: any NON-empty capture always
    /// logs (it can change the adopted resolvers), and an empty (masked) read logs at the
    /// transition INTO the masked state AND whenever the capture context (`reason`) changes —
    /// a masked→masked handoff under a new reason (e.g. `network-path-changed` from one masked
    /// network to another) is a distinct recapture attempt this diagnostic log exists to show,
    /// so it earns one line. Only SAME-reason repeats within one masked episode are suppressed:
    /// those were the no-information lines that flooded the log (rc9: 832 of 858 reads were
    /// `count=0` under one repeating reason). `lastLoggedCount`/`lastLoggedReason` describe the
    /// previous line this policy allowed; nil `lastLoggedCount` (nothing logged yet) always logs.
    public static func shouldLogDeviceDNSCapture(
        capturedCount: Int,
        reason: String,
        lastLoggedCount: Int?,
        lastLoggedReason: String?
    ) -> Bool {
        capturedCount > 0 || lastLoggedCount != capturedCount || lastLoggedReason != reason
    }
}
