import Foundation

/// Identifies each connectivity-health signal.
///
/// `linkPath` and `dataPath` are declared now, before their modules exist (Slices B and C), so the
/// id space is stable — a later signal is an ADD to this enum, never a renumber of the others, and
/// a supervisor can key a fixed set of signals from the start.
public enum ConnectivityHealthSignalID: String, Sendable, Equatable, CaseIterable {
    /// DNS resolution health — answered/unanswered, fallbacks, slow answers, outages (Slice A).
    case dnsResolution
    /// Network link/path health — path satisfied, offline/recovery transitions (Slice B).
    case linkPath
    /// Data-path health — the peer forwarding traffic (tx advancing, rx flat over a window) (Slice C).
    case dataPath
}

/// The pre-sampled evidence a ``ConnectivityHealthSignal`` reads.
///
/// Every conforming signal is a PURE function of this bundle: no I/O, no retained state, no queue
/// assumption. Sampling — and any retained baseline a windowed signal needs, such as Slice C's prior
/// tx/rx reading — is the provider's job on the correct queue and is handed in here. That keeps
/// `INV-QUEUE-1` (dnsStateQueue confinement) and `INV-MEM-1` (the ~50 MB NE ceiling) the caller's
/// contract rather than a hidden cost inside a signal, and keeps every verdict unit-testable without
/// a Network Extension. The struct is EXTENDED (never reshaped) as later signals need more evidence.
public struct ConnectivityHealthInputs: Equatable, Sendable {
    public let isConnected: Bool
    public let health: TunnelHealthSnapshot
    /// The chained data-path byte window, when sampled — the provider reads the engine's `statistics()`
    /// on the engine queue, holds the prior sample, and hands the delta in here. `nil` in DNS-only mode
    /// and before the first sample; only ``DataPathHealth`` reads it. Defaulted so signals that do not
    /// need it (DNS, link) and their call sites are untouched (the "extended, never reshaped" rule).
    public let dataPath: DataPathObservation?

    public init(
        isConnected: Bool,
        health: TunnelHealthSnapshot,
        dataPath: DataPathObservation? = nil
    ) {
        self.isConnected = isConnected
        self.health = health
        self.dataPath = dataPath
    }
}

/// One signal of whether the tunnel is actually carrying traffic.
///
/// DNS resolution, link/path, and data-path (peer forwarding) are all instances of the same
/// question. The `ConnectivityHealthSupervisor` (Slice D) composes their verdicts — gated by
/// ``DNSHealthAuthority`` ownership, never by an inline `isChainedUpstream` re-derivation — into a
/// single connectivity verdict and its recovery. A signal is pure by contract so the composition is
/// testable and cheap; it does not consult the authority itself (that is the supervisor's job).
public protocol ConnectivityHealthSignal: Sendable {
    var id: ConnectivityHealthSignalID { get }

    /// Evaluate the pre-sampled evidence into a verdict. Pure: no I/O, no retained state.
    func verdict(for inputs: ConnectivityHealthInputs, now: Date) -> HealthVerdict
}
