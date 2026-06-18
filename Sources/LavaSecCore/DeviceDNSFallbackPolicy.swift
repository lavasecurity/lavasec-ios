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

    // FUTURE (dns-recovery optimization C, pending rc/debug-log evidence):
    // preserveOnEmptyCapture is a stability heuristic — it stops a transient
    // masked read (iOS surfacing only Lava's tunnel DNS) from wiping working
    // resolvers. Its failure mode is the `send-failed` wedge: on a real handoff an
    // empty read PRESERVES the previous network's (now unreachable) resolvers.
    // #23 narrows the window by re-capturing at settle, but the residual hole is
    // an empty capture even at settle. A bounded capture-RETRY (re-read every ~1s
    // for N tries until non-empty, then give up and preserve) would make capture
    // genuinely nimble. Trade-off: a few extra reads during a transition. The
    // device-dns-captured count events (now exported via #23) should confirm how
    // often settle-time captures still come back empty before this is worth doing.
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
}
