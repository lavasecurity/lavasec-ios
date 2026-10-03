import Foundation

/// Bounded, address-free HTTP observations for an explicitly requested QA probe.
/// Session creation does not flush OS DNS or establish socket identity.
public struct HTTPProbeConnectionEvidence: Equatable, Sendable {
    /// Whether the system delivered task metrics at all; absence is not a fresh connection.
    public let metricsObserved: Bool
    /// Number of HTTP transactions reported by URLSession, including intermediate exchanges.
    public let transactionCount: Int
    /// Transactions which URLSession reported as reusing an existing connection.
    public let reusedConnectionCount: Int
    /// Only recognized HTTP protocol labels; no endpoint, address or credential fields.
    public let protocols: [String]

    /// Converts platform observations to the sanitized evidence schema. Nil represents
    /// unavailable metrics; an observed empty list remains distinct from unavailable.
    public init(reusedConnections: [Bool]?, protocols: [String?] = []) {
        metricsObserved = reusedConnections != nil
        transactionCount = reusedConnections?.count ?? 0
        reusedConnectionCount = reusedConnections?.filter { $0 }.count ?? 0
        let allowed = Set(["http/1.0", "http/1.1", "h2", "h3"])
        self.protocols = Array(Set(protocols.compactMap { $0 }.filter { allowed.contains($0) })).sorted()
    }

    /// Fields usable by the existing bounded VPN debug log, without collecting task URLs/IPs.
    public var logFields: [String: String] {
        ["metricsObserved": String(metricsObserved), "transactions": String(transactionCount),
         "reusedConnections": String(reusedConnectionCount), "protocols": protocols.joined(separator: ",")]
    }
}
