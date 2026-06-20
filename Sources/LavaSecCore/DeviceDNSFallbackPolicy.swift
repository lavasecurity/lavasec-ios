import Foundation

public enum DeviceDNSFallbackPolicy {
    public static let queryFallbackActivationThreshold = 3
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
