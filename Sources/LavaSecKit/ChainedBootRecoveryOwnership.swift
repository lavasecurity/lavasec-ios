/// Joins delivered physical-path and health-scheduling observations for one monitor generation.
/// Unknown/optimistic defaults and mismatched queue turns cannot authorize credential work.
public struct ChainedBootRecoveryPathGate: Sendable {
    /// The monitor/provider generation whose observations this gate accepts.
    public let generation: UInt64
    /// Genuine combined-gate rising edges, including an initial delivered satisfied path.
    public private(set) var satisfiedTransitionSerial: UInt64 = 0
    private var physical: (serial: UInt64, satisfied: Bool)?
    private var health: (serial: UInt64, satisfied: Bool)?
    private var lastCombinedIsSatisfied = false

    /// Starts with no delivered observations, even when other owners use optimistic defaults.
    public init(generation: UInt64) { self.generation = generation }

    /// Current readiness requires both queue turns for the latest observation to agree.
    public var isSatisfied: Bool {
        guard let physical, let health, physical.serial == health.serial else { return false }
        return physical.satisfied && health.satisfied
    }

    /// Records the immediate monitor callback, rejecting stale monitors and observations.
    public mutating func observePhysical(generation: UInt64, serial: UInt64, isSatisfied: Bool) {
        guard generation == self.generation,
              physical.map({ serial > $0.serial }) ?? true else { return }
        physical = (serial, isSatisfied)
        updateCombinedGate()
    }

    /// Records applied health scheduling state for that same physical observation.
    /// It may arrive first; a newer physical observation still makes an old health result stale.
    public mutating func observeHealth(generation: UInt64, serial: UInt64, isSatisfied: Bool) {
        guard generation == self.generation,
              health.map({ serial >= $0.serial }) ?? true else { return }
        health = (serial, isSatisfied)
        updateCombinedGate()
    }

    private mutating func updateCombinedGate() {
        // A current negative observation proves the AND gate down immediately. A positive
        // waits for matching delivery; duplicate satisfied callbacks must not invent edges.
        let latest = max(physical?.serial ?? 0, health?.serial ?? 0)
        if (physical?.serial == latest && physical?.satisfied == false)
            || (health?.serial == latest && health?.satisfied == false) {
            lastCombinedIsSatisfied = false
        }
        guard let physical, let health, physical.serial == health.serial else { return }
        let satisfied = physical.satisfied && health.satisfied
        if satisfied && !lastCombinedIsSatisfied { satisfiedTransitionSerial += 1 }
        lastCombinedIsSatisfied = satisfied
    }
}

/// Owns the single uncancellable readiness read across logical windows and provider lifecycles.
/// Cancellation does not release this slot: only completion with its exact identity can do so.
public struct ChainedBootRecoveryReadSlot: Sendable {
    private var owner: ChainedBootRecoveryPolicy.ReadToken?

    /// Creates an empty physical slot; reuse it across same-instance provider starts.
    public init() {}

    /// Whether a physical utility-queue read is still outstanding.
    public var isInFlight: Bool { owner != nil }

    /// Reserves the slot once; no lifecycle or logical cancellation may over-admit it.
    public mutating func admit(_ token: ChainedBootRecoveryPolicy.ReadToken) -> Bool {
        guard owner == nil else { return false }
        owner = token
        return true
    }

    /// Releases only the matching physical owner; stale/duplicate results leave newer work intact.
    public mutating func complete(_ token: ChainedBootRecoveryPolicy.ReadToken) -> Bool {
        guard owner == token else { return false }
        owner = nil
        return true
    }
}
