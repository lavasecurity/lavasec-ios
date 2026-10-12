import Foundation

/// Bounded read-only foreground-entry queries. Staging never changes a protection claim;
/// activation consumes the reply once, or falls back to normal expired-evidence handling.
public struct ChainedForegroundEntryPrefetch: Sendable {
    public static let maximumEntryAge: TimeInterval = 2
    public static let maximumSampleAge: TimeInterval = 0.5

    public struct Identity: Equatable, Sendable {
        public let providerLifecycleID: String
        public let sessionGeneration: UInt64
        public let transportGeneration: UInt64
        public let verificationEpoch: UInt64

        public init?(providerLifecycleID: String?, sessionGeneration: UInt64,
                     transportGeneration: UInt64, verificationEpoch: UInt64?) {
            guard let providerLifecycleID, !providerLifecycleID.isEmpty,
                  let verificationEpoch, verificationEpoch > 0,
                  sessionGeneration > 0, transportGeneration > 0 else { return nil }
            self.providerLifecycleID = providerLifecycleID
            self.sessionGeneration = sessionGeneration
            self.transportGeneration = transportGeneration
            self.verificationEpoch = verificationEpoch
        }

        public init?(_ session: ChainedRuntimeObservation.Session) {
            self.init(providerLifecycleID: session.providerLifecycleID,
                      sessionGeneration: session.generation, transportGeneration: session.transportGeneration,
                      verificationEpoch: session.verificationEpoch)
        }
    }

    public struct Token: Equatable, Sendable {
        public let generation: UInt64
        public let connection: UInt64
        public let identity: Identity
        fileprivate let startedAt: TimeInterval
    }

    public struct Candidate: Sendable {
        public let observation: ChainedRuntimeObservation
        /// Current canonical status, carried with the reply instead of reconstructing it in the app.
        public let providerReply: ChainedHandshakeStatus?
        /// Continuous-clock receipt time, retained on admission instead of renewing sample age.
        public let receivedAt: TimeInterval
    }

    private var generation: UInt64 = 0
    private var token: Token?
    private var candidate: Candidate?
    private var readCompleted = false
    private var candidateWasRetained = false

    public init() {}

    /// Unlock can precede opening Lava by minutes. Repeated foreground notifications may reuse
    /// an in-flight read. Foreground entry starts a new read while preserving a valid backup.
    public func isPending(now: TimeInterval) -> Bool {
        if let candidate, candidate.providerReply?.statusPublication != nil {
            return sampleIsCurrent(candidate, now: now)
        }
        guard let token, (0..<Self.maximumEntryAge).contains(now - token.startedAt) else { return false }
        return candidate.map { sampleIsCurrent($0, now: now) } ?? !readCompleted
    }

    public mutating func begin(connection: UInt64, identity: Identity, now: TimeInterval,
                               retainingCandidate: Bool = false) -> Token {
        let retained = retainingCandidate && token?.connection == connection && token?.identity == identity
            ? candidate.flatMap { sampleIsCurrent($0, now: now) ? $0 : nil } : nil
        cancel()
        let next = Token(generation: generation, connection: connection, identity: identity, startedAt: now)
        token = next
        candidate = retained
        candidateWasRetained = retained != nil
        return next
    }

    @discardableResult
    public mutating func stage(_ observation: ChainedRuntimeObservation?, for expected: Token,
                               now: TimeInterval) -> Bool {
        guard token == expected else { return false }
        readCompleted = true
        guard candidate == nil || candidateWasRetained,
              (0..<Self.maximumEntryAge).contains(now - expected.startedAt),
              case let .chained(session?)? = observation,
              Identity(session) == expected.identity,
              session.health != nil, session.healthSampledAt != nil else { return false }
        // Adverse current runtime/health evidence is retained too. The shared reducer applies
        // its precedence at activation; prefetch must never turn it into healthy evidence.
        candidate = Candidate(observation: .chained(session: session), providerReply: nil, receivedAt: now)
        candidateWasRetained = false
        return true
    }

    /// The caller fences IPC to the exact live NE session and connected date. A genuine wake
    /// can change verification/transport identity: that current reply must reach the reducer,
    /// which invalidates old proof itself. Legacy replies retain the stricter identity gate.
    @discardableResult
    public mutating func stageProviderReply(_ reply: ChainedHandshakeStatus?, for expected: Token,
                                           now: TimeInterval) -> Bool {
        guard token == expected else { return false }
        readCompleted = true
        guard candidate == nil || candidateWasRetained,
              (0..<Self.maximumEntryAge).contains(now - expected.startedAt),
              let reply, let observation = ChainedRuntimeObservation.fromTunnelReply(reply) else { return false }
        if let publication = reply.statusPublication {
            // Runtime lifecycle IDs disappear at invalidation; the terminal publication keeps
            // its writer ID. Exact-session inactivity is authoritative independently of that envelope.
            guard observation == .inactive || publication.providerLifecycleID == reply.providerLifecycleID else { return false }
        } else if observation != .dnsOnly && observation != .inactive {
            return stage(observation, for: expected, now: now)
        }
        candidate = Candidate(observation: observation, providerReply: reply, receivedAt: now)
        candidateWasRetained = false
        return true
    }

    public mutating func consume(connection: UInt64?, identity: Identity?, now: TimeInterval) -> Candidate? {
        defer { cancel() }
        guard let token, let candidate,
              token.connection == connection, token.identity == identity,
              candidate.providerReply?.statusPublication != nil || (0..<Self.maximumEntryAge).contains(now - token.startedAt),
              sampleIsCurrent(candidate, now: now) else { return nil }
        return candidate
    }

    private func sampleIsCurrent(_ candidate: Candidate, now: TimeInterval) -> Bool {
        // Canonical status is independently checked against its original absolute lease by the
        // app reader. Request/legacy timing cannot shorten or renew that publication deadline.
        let limit = candidate.providerReply?.statusPublication != nil
            ? ProtectionStatusPublication.leaseSeconds : Self.maximumSampleAge
        return (0..<limit).contains(now - candidate.receivedAt)
    }

    public mutating func cancel() {
        generation &+= 1
        token = nil
        candidate = nil
        readCompleted = false
        candidateWasRetained = false
    }
}
