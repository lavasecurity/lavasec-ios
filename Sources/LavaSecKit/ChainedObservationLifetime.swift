/// Admission tokens for app-side tunnel observations. Visibility and sampler replacement
/// invalidate queued replies without changing the tunnel's connection or forwarding evidence.
public struct ChainedObservationLifetime: Equatable, Sendable {
    /// Whether the application's synchronous lifecycle owner permits sampling.
    public private(set) var isActive = false
    /// Monotonically distinguishes sampling work, including work for the same connection.
    public private(set) var generation: UInt64 = 0
    /// Distinguishes application activity intervals without retiring foreground work when a
    /// sampler is replaced or stops after an authoritative DNS-only observation.
    public private(set) var activityGeneration: UInt64 = 0

    /// Starts inactive until the application lifecycle owner establishes its current state.
    public init() {}

    /// Returns whether visibility changed. Repeated activation does not replace a live sampler.
    @discardableResult
    public mutating func setActive(_ active: Bool) -> Bool {
        guard active != isActive else { return false }
        isActive = active
        activityGeneration &+= 1
        invalidateSampling()
        return true
    }

    /// Starts a new observation interval only while active, superseding any prior token.
    public mutating func beginSampling() -> UInt64? {
        guard isActive else { return nil }
        invalidateSampling()
        return generation
    }

    /// Ends pending work without deciding anything about the actual tunnel.
    public mutating func invalidateSampling() {
        generation &+= 1
    }

    /// Checked after suspension and before a reply can reach the connection reducer.
    public func accepts(_ token: UInt64) -> Bool {
        isActive && token == generation
    }
}
