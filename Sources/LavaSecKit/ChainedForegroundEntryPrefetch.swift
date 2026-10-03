import Foundation

/// A single read-only foreground-entry query. Staging never changes a protection claim;
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
        /// Continuous-clock receipt time, retained on admission instead of renewing sample age.
        public let receivedAt: TimeInterval
    }

    private var generation: UInt64 = 0
    private var token: Token?
    private var candidate: Candidate?

    public init() {}

    public mutating func begin(connection: UInt64, identity: Identity, now: TimeInterval) -> Token {
        cancel()
        let next = Token(generation: generation, connection: connection, identity: identity, startedAt: now)
        token = next
        return next
    }

    @discardableResult
    public mutating func stage(_ observation: ChainedRuntimeObservation?, for expected: Token,
                               now: TimeInterval) -> Bool {
        guard token == expected, candidate == nil,
              (0..<Self.maximumEntryAge).contains(now - expected.startedAt),
              case let .chained(session?)? = observation,
              Identity(session) == expected.identity,
              session.health != nil, session.healthSampledAt != nil else { return false }
        // Adverse current runtime/health evidence is retained too. The shared reducer applies
        // its precedence at activation; prefetch must never turn it into healthy evidence.
        candidate = Candidate(observation: .chained(session: session), receivedAt: now)
        return true
    }

    public mutating func consume(connection: UInt64?, identity: Identity?, now: TimeInterval) -> Candidate? {
        defer { cancel() }
        guard let token, let candidate,
              token.connection == connection, token.identity == identity,
              (0..<Self.maximumEntryAge).contains(now - token.startedAt),
              (0..<Self.maximumSampleAge).contains(now - candidate.receivedAt) else { return nil }
        return candidate
    }

    public mutating func cancel() {
        generation &+= 1
        token = nil
        candidate = nil
    }
}
