import Foundation

/// The prompt wire reply describing the tunnel's current chained-upstream runtime truth.
///
/// `lifecycleIsActive` is the authoritative first discriminator. While it is true, `isChained`
/// identifies the latched data-path mode; an inactive reply carries `isChained == false` regardless
/// of its prior mode. A live chained lifecycle stays chained while its outage driver is between
/// runners, with generation 0 and no handshake or forwarding evidence. Callers can therefore
/// distinguish inactive, active-without-a-runner, and active-with-a-session without inferring
/// lifecycle from optional engine statistics.
///
/// `hasHandshake` is the engine's current `timeSinceLastHandshake != nil`. `everHandshaked`
/// distinguishes a session that has never handshaked from one whose handshake later expired. The
/// provider latches that history per session generation; both fields are meaningful only for an
/// active chained lifecycle with a current session.
public struct ChainedHandshakeStatus: Codable, Equatable, Sendable {
    /// Whether an active lifecycle's live data-path latch selects a chained upstream.
    ///
    /// This is false both for active DNS-only mode and an inactive lifecycle; consult
    /// ``lifecycleIsActive`` first.
    public let isChained: Bool

    /// Whether the current chained engine session has a non-expired handshake.
    public let hasHandshake: Bool

    /// Whether the current chained engine session has handshaked at least once in its generation.
    public let everHandshaked: Bool

    /// Forwarding evidence from `ChainedRunnerStatistics.forwardedNonDNSByteCount`.
    ///
    /// The name is retained for wire compatibility. The provider excludes replies from its own DNS
    /// resolver in full-tunnel mode, so any positive delta is evidence that the peer relayed general
    /// traffic. The app differences it within the session/transport generation pair. It is 0
    /// while inactive, in DNS-only mode, and while a chained lifecycle has no current session.
    public var receivedByteCount: UInt64 = 0

    /// The engine session generation that ``receivedByteCount`` belongs to.
    ///
    /// The generation advances when a runner is adopted or rebuilt, where its byte totals reset.
    /// Generation 0 marks an inactive lifecycle, DNS-only mode, or a latched chained lifecycle with
    /// no current runner.
    public var sessionGeneration: UInt64 = 0

    /// Forwarding-counter incarnation within the session; legacy replies decode as 0.
    public var transportGeneration: UInt64 = 0

    /// Current provider-verified setup with no known pending demand or recovery. Legacy replies
    /// have no such evidence and decode false. This does not prove forwarded traffic.
    public var setupReady: Bool = false

    /// Existing provider incarnation, copied from its live latch. Absent on older providers.
    public var providerLifecycleID: String?
    /// Driver-owned same-transport evidence epoch. Absent on older providers.
    public var verificationEpoch: UInt64?
    /// Cumulative bytes present at this epoch's boundary; never forwarded proof for that epoch.
    public var forwardingBaseline: UInt64 = 0
    /// Fresh provider condition, separate from setup and forwarding milestones.
    public var runtimeCondition: ChainedRuntimeCondition = .normal
    /// Current in-memory provider health, sampled on its state queue without a flush.
    public var health: TunnelHealthSnapshot?

    /// Whether the provider still has an active tunnel lifecycle.
    ///
    /// This is independent of ``isChained`` and runner availability. Replies from extensions built
    /// before this field existed decode as `true`: receiving the prompt reply itself meant that older
    /// provider was alive and handling a message.
    public let lifecycleIsActive: Bool

    /// Decode-only provenance for the app/extension upgrade window. Older extensions overloaded
    /// `isChained == false` for both DNS-only mode and a temporary chained runner gap, so that shape
    /// is not authoritative unless the lifecycle field was actually present on the wire.
    fileprivate let lifecycleIsActiveWasExplicit: Bool

    /// Creates a prompt chained-runtime reply.
    ///
    /// - Parameters:
    ///   - isChained: Whether an active lifecycle's current data-path latch selects a chained
    ///     upstream. False when the lifecycle is inactive.
    ///   - hasHandshake: Whether the current engine session has a non-expired handshake.
    ///   - everHandshaked: Whether that session has handshaked at least once.
    ///   - receivedByteCount: Cumulative forwarded non-DNS bytes for ``sessionGeneration``.
    ///   - sessionGeneration: Current engine session identity, or 0 when no runner is current.
    ///   - lifecycleIsActive: Whether a tunnel lifecycle still owns this reply. Defaults to `true`
    ///     for source compatibility with callers predating the field.
    ///   - transportGeneration: Forwarding tally incarnation, advancing when its channel is rebound.
    ///   - setupReady: Fresh provider-verified initial-transport setup without known demand failure.
    public init(
        isChained: Bool, hasHandshake: Bool, everHandshaked: Bool,
        receivedByteCount: UInt64 = 0, sessionGeneration: UInt64 = 0,
        lifecycleIsActive: Bool = true,
        transportGeneration: UInt64 = 0,
        setupReady: Bool = false,
        providerLifecycleID: String? = nil,
        verificationEpoch: UInt64? = nil,
        forwardingBaseline: UInt64 = 0,
        runtimeCondition: ChainedRuntimeCondition = .normal,
        health: TunnelHealthSnapshot? = nil
    ) {
        self.isChained = isChained
        self.hasHandshake = hasHandshake
        self.everHandshaked = everHandshaked
        self.receivedByteCount = receivedByteCount
        self.sessionGeneration = sessionGeneration
        self.transportGeneration = transportGeneration
        self.setupReady = setupReady
        self.providerLifecycleID = providerLifecycleID
        self.verificationEpoch = verificationEpoch
        self.forwardingBaseline = forwardingBaseline
        self.runtimeCondition = runtimeCondition
        self.health = health
        self.lifecycleIsActive = lifecycleIsActive
        lifecycleIsActiveWasExplicit = true
    }

    private enum CodingKeys: String, CodingKey {
        case isChained, hasHandshake, everHandshaked, receivedByteCount, sessionGeneration
        case lifecycleIsActive, transportGeneration, setupReady
        case providerLifecycleID, verificationEpoch, forwardingBaseline, runtimeCondition, health
    }

    /// Decodes current and older prompt replies without dropping newly added evidence fields.
    ///
    /// Stored-property defaults do not make synthesized decoding tolerate absent keys. Forwarding
    /// fields therefore default to 0 for replies predating them, and lifecycle activity defaults to
    /// `true` for replies predating the authoritative lifecycle bit. The three original mode and
    /// handshake fields remain required because a reply missing one is genuinely malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isChained = try container.decode(Bool.self, forKey: .isChained)
        hasHandshake = try container.decode(Bool.self, forKey: .hasHandshake)
        everHandshaked = try container.decode(Bool.self, forKey: .everHandshaked)
        receivedByteCount =
            try container.decodeIfPresent(UInt64.self, forKey: .receivedByteCount) ?? 0
        sessionGeneration =
            try container.decodeIfPresent(UInt64.self, forKey: .sessionGeneration) ?? 0
        transportGeneration = try container.decodeIfPresent(UInt64.self, forKey: .transportGeneration) ?? 0
        setupReady = try container.decodeIfPresent(Bool.self, forKey: .setupReady) ?? false
        providerLifecycleID = try container.decodeIfPresent(String.self, forKey: .providerLifecycleID)
        verificationEpoch = try container.decodeIfPresent(UInt64.self, forKey: .verificationEpoch)
        forwardingBaseline = try container.decodeIfPresent(UInt64.self, forKey: .forwardingBaseline) ?? 0
        runtimeCondition = try container.decodeIfPresent(ChainedRuntimeCondition.self, forKey: .runtimeCondition) ?? .normal
        health = try container.decodeIfPresent(TunnelHealthSnapshot.self, forKey: .health)
        if let explicitLifecycle =
            try container.decodeIfPresent(Bool.self, forKey: .lifecycleIsActive)
        {
            lifecycleIsActive = explicitLifecycle
            lifecycleIsActiveWasExplicit = true
        } else {
            lifecycleIsActive = true
            lifecycleIsActiveWasExplicit = false
        }
    }

    /// Compares runtime-adaptation semantics, including decode-only field-presence provenance.
    /// Legacy and explicit-active false-mode replies adapt differently during an extension upgrade,
    /// so treating them as equal would violate substitutability for ``fromTunnelReply(_:)``.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isChained == rhs.isChained
            && lhs.hasHandshake == rhs.hasHandshake
            && lhs.everHandshaked == rhs.everHandshaked
            && lhs.receivedByteCount == rhs.receivedByteCount
            && lhs.sessionGeneration == rhs.sessionGeneration
            && lhs.transportGeneration == rhs.transportGeneration
            && lhs.setupReady == rhs.setupReady
            && lhs.providerLifecycleID == rhs.providerLifecycleID
            && lhs.verificationEpoch == rhs.verificationEpoch
            && lhs.forwardingBaseline == rhs.forwardingBaseline
            && lhs.runtimeCondition == rhs.runtimeCondition
            && lhs.health == rhs.health
            && lhs.lifecycleIsActive == rhs.lifecycleIsActive
            && lhs.lifecycleIsActiveWasExplicit == rhs.lifecycleIsActiveWasExplicit
    }

    /// Encodes current replies with authoritative lifecycle activity while preserving a decoded
    /// legacy reply's missing-key provenance if a caller forwards it through another codec hop.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isChained, forKey: .isChained)
        try container.encode(hasHandshake, forKey: .hasHandshake)
        try container.encode(everHandshaked, forKey: .everHandshaked)
        try container.encode(receivedByteCount, forKey: .receivedByteCount)
        try container.encode(sessionGeneration, forKey: .sessionGeneration)
        try container.encode(transportGeneration, forKey: .transportGeneration)
        try container.encode(setupReady, forKey: .setupReady)
        try container.encodeIfPresent(providerLifecycleID, forKey: .providerLifecycleID)
        try container.encodeIfPresent(verificationEpoch, forKey: .verificationEpoch)
        try container.encode(forwardingBaseline, forKey: .forwardingBaseline)
        try container.encode(runtimeCondition, forKey: .runtimeCondition)
        try container.encodeIfPresent(health, forKey: .health)
        if lifecycleIsActiveWasExplicit {
            try container.encode(lifecycleIsActive, forKey: .lifecycleIsActive)
        }
    }

    /// Encodes the reply for the cross-process provider-message boundary.
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// Decodes a nonempty provider-message reply, returning `nil` for absent or malformed data.
    public static func decode(_ data: Data?) -> ChainedHandshakeStatus? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ChainedHandshakeStatus.self, from: data)
    }
}

public extension ChainedRuntimeObservation {
    /// Adapts a prompt tunnel reply into the reducer's authoritative runtime observation.
    ///
    /// A missing IPC reply stays unknown. For a current reply, lifecycle activity is considered
    /// before the latched mode, and generation 0 is the explicit chained-without-a-runner marker.
    /// A legacy reply that omits lifecycle activity and says non-chained is also unknown: older
    /// providers used that shape during runner gaps as well as for DNS-only mode. Handshake flags
    /// are presentation evidence only and do not establish forwarded traffic.
    static func fromTunnelReply(_ reply: ChainedHandshakeStatus?) -> Self? {
        guard let reply else { return nil }
        guard reply.lifecycleIsActive else { return .inactive }
        guard reply.isChained else {
            guard reply.lifecycleIsActiveWasExplicit else { return nil }
            return .dnsOnly
        }
        guard reply.sessionGeneration != 0 else { return .chained(session: nil) }
        return .chained(
            session: .init(
                generation: reply.sessionGeneration,
                forwardedBytes: reply.receivedByteCount,
                transportGeneration: reply.transportGeneration,
                setupReady: reply.lifecycleIsActiveWasExplicit && reply.hasHandshake && reply.setupReady,
                providerLifecycleID: reply.providerLifecycleID,
                verificationEpoch: reply.verificationEpoch,
                forwardingBaseline: reply.forwardingBaseline,
                runtimeCondition: reply.runtimeCondition,
                health: reply.health, healthSampledAt: Date()))
    }
}
