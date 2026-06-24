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
}
