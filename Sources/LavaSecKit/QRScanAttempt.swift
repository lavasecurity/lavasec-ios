/// Recognition ownership for a retained camera page. Navigation starts a fresh
/// attempt; activity changes fence delayed work without clearing an accepted scan.
public struct QRScanAttempt: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isVisible = false
    public private(set) var isActive = false
    public private(set) var hasAcceptedMatch = false
    private var lastValue: String?

    public init() {}

    public mutating func appear(active: Bool) {
        generation &+= 1
        isVisible = true
        isActive = active
        hasAcceptedMatch = false
        lastValue = nil
    }

    public mutating func disappear() {
        generation &+= 1
        isVisible = false
        isActive = false
    }

    public mutating func setActive(_ active: Bool) {
        generation &+= 1
        isActive = active && isVisible
    }

    public func permitsDelivery(generation expected: UInt64) -> Bool {
        generation == expected && isVisible && isActive && !hasAcceptedMatch
    }

    /// Invalid input suppresses only consecutive duplicate frames, never the
    /// next different value. Acceptance ends delivery until the next appearance.
    public mutating func receive(_ value: String, generation expected: UInt64,
                                 decode: (String) -> Bool) -> Bool {
        guard permitsDelivery(generation: expected), !value.isEmpty, value != lastValue else { return false }
        lastValue = value
        let accepted = decode(value)
        hasAcceptedMatch = accepted
        return accepted
    }
}
