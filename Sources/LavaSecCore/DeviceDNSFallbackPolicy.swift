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
