import Darwin
import Foundation

/// A reboot-scoped clock whose age includes device sleep and cannot be extended by a wall-clock edit.
public enum ProtectionStatusPublicationClock {
    /// Adjacent display and continuous-clock readings, shared across the app and provider processes.
    public struct Sample: Equatable, Sendable {
        public let date: Date
        public let bootSessionID: String?
        public let continuousNanoseconds: UInt64
        public init(date: Date, bootSessionID: String?, continuousNanoseconds: UInt64) {
            self.date = date
            self.bootSessionID = bootSessionID
            self.continuousNanoseconds = continuousNanoseconds
        }
        /// Fences physical work and live identity proof without comparing editable wall time.
        public func isAtOrAfter(_ earlier: Self) -> Bool {
            bootSessionID != nil && bootSessionID == earlier.bootSessionID
                && continuousNanoseconds >= earlier.continuousNanoseconds
        }
    }
    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    /// Reads the same boot domain as the device log, with a continuous clock for the freshness lease.
    public static func capture() -> Sample {
        let domain = DeviceLogObservationClock.capture().order?.bootSessionID
        return .init(date: Date(), bootSessionID: domain,
                     continuousNanoseconds: UInt64(Double(mach_continuous_time()) * nanosecondsPerTick))
    }
}

/// Identity proof from a reply fenced to the exact live NE session/connected epoch.
/// The two cached boot domains may differ after a wall-clock edit; only this live proof bridges them.
public struct ProtectionStatusPublicationConnectionProof: Equatable, Sendable {
    public let providerLifecycleID: String
    public let providerBootSessionID: String
    public let connectedAt: Date
    public let verifiedAt: ProtectionStatusPublicationClock.Sample
    public init(publication: ProtectionStatusPublication, connectedAt: Date,
                verifiedAt: ProtectionStatusPublicationClock.Sample) {
        providerLifecycleID = publication.providerLifecycleID
        providerBootSessionID = publication.bootSessionID
        self.connectedAt = connectedAt
        self.verifiedAt = verifiedAt
    }
    /// A domain correspondence is valid only in the observer's original boot.
    public func matchesDomain(_ providerBootSessionID: String, clock: ProtectionStatusPublicationClock.Sample) -> Bool {
        !self.providerBootSessionID.isEmpty && self.providerBootSessionID == providerBootSessionID
            && clock.isAtOrAfter(verifiedAt)
    }
    /// A domain bridge cannot admit a different provider incarnation.
    public func matches(_ publication: ProtectionStatusPublication, clock: ProtectionStatusPublicationClock.Sample) -> Bool {
        providerLifecycleID == publication.providerLifecycleID && matchesDomain(publication.bootSessionID, clock: clock)
    }
}

/// Minimal provider-owned operational truth. Observer activation and missed replies never renew it.
public struct ProtectionStatusPublication: Codable, Equatable, Sendable {
    /// Matches the existing confirmed observation cadence; it never starts network probes.
    public static let heartbeatSeconds: TimeInterval = 5
    /// One missed heartbeat is tolerated. The absolute deadline is exclusive and includes sleep.
    public static let leaseSeconds: TimeInterval = 10
    public let schemaVersion: Int
    public let providerLifecycleID: String
    public let revision: UInt64
    public let observedAt: Date
    public let bootSessionID: String
    public let continuousNanoseconds: UInt64
    public let sessionGeneration: UInt64?
    public let transportGeneration: UInt64?
    public let verificationEpoch: UInt64?
    public let status: ProtectionStatus

    /// Admits only this live provider, this connected epoch, and a bounded continuous-clock age.
    public func isValid(clock: ProtectionStatusPublicationClock.Sample,
                        providerLifecycleID: String?, connectedAt: Date?,
                        connectionProof: ProtectionStatusPublicationConnectionProof? = nil) -> Bool {
        // A reply fenced to the exact NE session/connected date proves this incarnation belongs
        // to the epoch. Retain that boot-scoped proof across wall-clock edits (INV-STATUS-1).
        // Until live proof arrives, the file-only path keeps its conservative date barrier.
        let liveEpochIsVerified = connectionProof?.matches(self, clock: clock) == true
        if let connectionProof, connectionProof.connectedAt != connectedAt { return false }
        guard schemaVersion == 1, revision > 0, !self.providerLifecycleID.isEmpty, !bootSessionID.isEmpty,
              self.providerLifecycleID == providerLifecycleID,
              let connectedAt, liveEpochIsVerified || observedAt >= connectedAt,
              bootSessionID == clock.bootSessionID || liveEpochIsVerified,
              clock.continuousNanoseconds >= continuousNanoseconds else { return false }
        return Double(clock.continuousNanoseconds - continuousNanoseconds) / 1_000_000_000 < Self.leaseSeconds
    }
    /// Continuous time remaining, for an observer's cancellation-scoped expiry task.
    public func remainingLease(clock: ProtectionStatusPublicationClock.Sample,
        connectionProof: ProtectionStatusPublicationConnectionProof? = nil) -> TimeInterval {
        guard bootSessionID == clock.bootSessionID || connectionProof?.matches(self, clock: clock) == true,
              clock.continuousNanoseconds >= continuousNanoseconds else { return 0 }
        return max(0, Self.leaseSeconds - Double(clock.continuousNanoseconds - continuousNanoseconds) / 1_000_000_000)
    }

    /// Only a fresh foreign publication newer than the identity observation can challenge cached ownership.
    /// Expired/previous-boot files and older retired writers cannot erase fresher live IPC proof.
    public func requiresIdentityRevalidation(providerLifecycleID: String?,
        verifiedAt: ProtectionStatusPublicationClock.Sample?, clock: ProtectionStatusPublicationClock.Sample,
        connectionProof: ProtectionStatusPublicationConnectionProof? = nil) -> Bool {
        // A bridged domain can reveal a newer foreign writer, but never authorize its positive status.
        guard self.providerLifecycleID != providerLifecycleID,
              bootSessionID == clock.bootSessionID || connectionProof?.matchesDomain(bootSessionID, clock: clock) == true,
              clock.continuousNanoseconds >= continuousNanoseconds,
              Double(clock.continuousNanoseconds - continuousNanoseconds) / 1_000_000_000 < Self.leaseSeconds
        else { return false }
        guard let verifiedAt else { return true }
        return verifiedAt.bootSessionID != clock.bootSessionID || continuousNanoseconds > verifiedAt.continuousNanoseconds
    }
}

/// Retains setup/forwarding milestones in the provider, independently of any observer's lifetime.
/// The shared reducer's app effects are deliberately ignored: publishing cannot arm, repair or reconnect.
public struct ProtectionStatusPublisher: Sendable {
    private var state = ChainedConnectLifecyclePolicy.State()
    private var providerLifecycleID: String?
    private var connection: UInt64?
    private var revision: UInt64 = 0
    public init() {}

    /// Samples real provider state. Identity, transport and verification changes invalidate old proof.
    public mutating func observe(_ evidence: ProtectionStatusEvidence,
                                 clock: ProtectionStatusPublicationClock.Sample) -> ProtectionStatusPublication? {
        guard let id = evidence.providerLifecycleID, !id.isEmpty, let boot = clock.bootSessionID else { return nil }
        // INV-STATUS-1: reducer deadlines use the same sleep-inclusive clock as the lease.
        // Wall dates remain presentation/health timestamps and cannot fast-forward establishment.
        let elapsedNow = Double(clock.continuousNanoseconds) / 1_000_000_000
        if providerLifecycleID != id {
            state = .init()
            revision = 0
            providerLifecycleID = id
            let effects = ChainedConnectLifecyclePolicy.reduce(state: &state,
                event: .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false,
                    now: elapsedNow))
            for case .startSampling(let value) in effects { connection = value }
        }
        if let connection {
            let session: ChainedRuntimeObservation.Session? = if let generation = evidence.sessionGeneration,
                let bytes = evidence.forwardedBytes {
                .init(generation: generation, forwardedBytes: bytes,
                    transportGeneration: evidence.transportGeneration ?? 0, setupReady: evidence.setupReady == true,
                    providerLifecycleID: id, verificationEpoch: evidence.verificationEpoch,
                    forwardingBaseline: evidence.forwardingBaseline ?? 0,
                    runtimeCondition: evidence.runtimeCondition ?? .normal,
                    health: evidence.health, healthSampledAt: evidence.sampledAt)
            } else { nil }
            let observation: ChainedRuntimeObservation = !evidence.lifecycleIsActive ? .inactive
                : evidence.isChained ? .chained(session: session) : .dnsOnly
            ChainedConnectLifecyclePolicy.reduce(state: &state, event: .observed(connection: connection,
                observation: observation, now: elapsedNow))
        }
        let projection = state.projection
        let pause = evidence.pauseUntil.flatMap { $0 > clock.date ? $0 : nil }
        let status: ProtectionStatus = !evidence.lifecycleIsActive ? .unavailable : .resolve(lifecycle: .connected,
            pauseUntil: pause, chainedEstablishing: projection.claim == .establishing,
            observationUnavailable: projection.claim == .checking,
            forwardingUnconfirmed: projection.claim == .unconfirmed, setupReady: projection.setupReady,
            runtimeCondition: evidence.runtimeCondition ?? .normal,
            connectivity: ProtectionConnectivityPolicy.assessment(isConnected: true, health: evidence.health,
                now: clock.date).severity)
        revision &+= 1
        return .init(schemaVersion: 1, providerLifecycleID: id, revision: revision,
            observedAt: clock.date, bootSessionID: boot, continuousNanoseconds: clock.continuousNanoseconds,
            sessionGeneration: evidence.sessionGeneration, transportGeneration: evidence.transportGeneration,
            verificationEpoch: evidence.verificationEpoch, status: status)
    }
}

/// One ordered publication for every UI facet. A late reply cannot undo a newer failure.
public struct ProtectionStatusPublicationReader: Sendable {
    public private(set) var publication: ProtectionStatusPublication?
    public init() {}
    /// Missing, expired or out-of-order replies leave the existing deadline untouched.
    @discardableResult public mutating func admit(_ candidate: ProtectionStatusPublication?,
        clock: ProtectionStatusPublicationClock.Sample, providerLifecycleID: String?, connectedAt: Date?,
        connectionProof: ProtectionStatusPublicationConnectionProof? = nil) -> Bool {
        guard let candidate, candidate.isValid(clock: clock, providerLifecycleID: providerLifecycleID,
            connectedAt: connectedAt, connectionProof: connectionProof) else { return false }
        if let previous = publication, previous.providerLifecycleID == candidate.providerLifecycleID {
            guard candidate.revision > previous.revision,
                  candidate.continuousNanoseconds >= previous.continuousNanoseconds else { return false }
        }
        publication = candidate
        return true
    }
    /// Expiry is observation uncertainty; it never requests a tunnel mutation.
    public func status(clock: ProtectionStatusPublicationClock.Sample,
                       providerLifecycleID: String?, connectedAt: Date?,
                       connectionProof: ProtectionStatusPublicationConnectionProof? = nil) -> ProtectionStatus {
        guard let publication, publication.isValid(clock: clock, providerLifecycleID: providerLifecycleID,
            connectedAt: connectedAt, connectionProof: connectionProof) else { return .unavailable }
        if case .paused(let until) = publication.status, until <= clock.date { return .unavailable }
        return publication.status
    }
}
