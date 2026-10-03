import Foundation

/// What the data path saw, sampled by whoever is timing the tunnel's health.
///
/// Two booleans rather than instants, because the runner has no clock. It records THAT
/// something happened; the reader stamps it with its own monotonic reading, which is the only
/// clock the budget is ever measured on.
public struct ChainedLivenessSample: Equatable, Sendable {
    /// A TRANSPORT DATA datagram from the peer decrypted successfully.
    ///
    /// THE SIGNAL THE OUTAGE PREDICATE IS BUILT ON, because it is the one no remote party can
    /// manufacture: producing it requires the peer's session keys. Keepalives count — they are
    /// transport data with an empty payload — and that is the point, since this measures
    /// whether the LINK works, not whether the peer's egress does.
    ///
    /// NOT every successful decapsulation, and the difference is a forgery this used to accept.
    /// A handshake message whose mac2 fails while the rate limiter is under load is answered
    /// with a cookie reply (`boringtun/src/noise/rate_limiter.rs:177-185`), which `decapsulate`
    /// returns as an ordinary success before any Noise processing
    /// (`boringtun/src/noise/mod.rs:293-296`) — and mac1 is keyed on OUR static public key,
    /// which is not a secret from anyone who can address us.
    ///
    /// A GENUINELY PROCESSED handshake still counts, and excluding all of them was a worse bug
    /// than the one it fixed: on every retry we initiate, so the peer's authenticated response
    /// is answered by OUR keepalive and the peer sends nothing back — a type-4-only rule
    /// surrenders a recovered session at the outage deadline. The two are told apart by what
    /// the engine emits in reply, which is type 3 only for the cookie path; see
    /// ``ChainedSessionRunner/provesPeerKeyPossession(inboundMessageType:operation:outboundMessageType:)``.
    /// pinned: ChainedSessionRunnerTests.testAHandshakeResponseCountsAsPeerLiveness
    /// pinned: ChainedSessionRunnerTests.testACookieReplyIsNotEvidenceThePeerIsAlive
    ///
    /// A FAILED decapsulation proves nothing either: `protocolViolation`, `noCurrentSession`
    /// and an oversized datagram are all producible by anyone who can reach our UDP port.
    /// pinned: ChainedSessionRunnerTests.testOnlyAnAuthenticatedDatagramCountsAsPeerLiveness
    public var sawAuthenticatedPeerDatagram: Bool
    /// An IPv4 packet the peer forwarded FROM THE INTERNET was written into the tunnel.
    ///
    /// DELIVERY IS THE WHOLE CONTRACT, and the earlier wording — "arrived from the peer and was
    /// acted on, delivered or dropped as IPv6" — described a signal the runner does not emit
    /// (Codex, PR #482). It is set at exactly one place, the `.deliver` verdict in
    /// `ChainedSessionRunner.deliverOnQueue`, which is reached only by a decrypted IPv4 packet
    /// whose inner source cleared the peer's AllowedIPs. Everything else a datagram from the
    /// peer can turn into leaves it false, and each exclusion is the same failure: a peer whose
    /// WireGuard link is healthy and whose IPv4 egress is DEAD can produce all of them forever,
    /// so crediting any of them holds the outage clock at zero through exactly the fault
    /// chained mode exists to bound.
    ///
    /// - An inbound IPv6 packet is dropped, not delivered. This tunnel drops every outbound
    ///   IPv6 packet locally, so an inbound one answers nothing this session carried.
    ///   pinned: ChainedSessionRunnerTests.testInboundIPv6IsNotEvidenceTheTunnelIsWorking
    /// - A keepalive carries no inner packet at all and lands on `.idle`.
    ///   pinned: ChainedSessionRunnerTests.testAKeepalivingPeerWithNoReturnDataIsNotFlowing
    /// - A packet claiming an inner source the peer was never granted is refused by AllowedIPs,
    ///   because the misbehaving peer must not be the one certifying the tunnel.
    ///   pinned: ChainedSessionRunnerTests.testASpoofedSourceIsNotEvidenceTheTunnelIsWorking
    /// - The tunnel's own tick output is not inbound anything.
    ///   pinned: ChainedSessionRunnerTests.testATicksOwnOutputDoesNotCertifyLiveness
    ///
    /// Not what DETECTION rests on — that is ``sawAuthenticatedPeerDatagram``, which no remote
    /// party can manufacture. This is the RECOVERY half of the predicate (see
    /// ``ChainedOutageDriver``): it clears the unanswered-send clock and ends an outage in
    /// progress. Weaker evidence is acceptable in that direction, which is why an ICMP
    /// destination-unreachable — the peer reporting it could NOT forward — still sets this. It
    /// is delivered like any other IPv4 packet, because dropping it would break PMTUD and TCP
    /// error signalling, and a peer whose return path carries errors is a peer whose return
    /// path carries packets.
    public var sawInboundData: Bool
    /// We sent something the peer is protocol-obliged to answer.
    ///
    /// A non-empty data packet (the peer owes a keepalive within `KEEPALIVE_TIMEOUT`) or a
    /// handshake initiation (it owes a response). NOT the post-handshake empty keepalive the
    /// engine emits on its own, and NOT the tick's output — the peer owes nothing for either, so
    /// arming a silence clock on them would be waiting for an answer that was never due.
    public var sawObligingSend: Bool
    /// We sent GENERAL (non-DNS) user traffic the peer is obliged to forward to the internet.
    ///
    /// The subset of ``sawObligingSend`` that is the user's own IPv4 traffic through the tunnel —
    /// set only on the `.encapsulate` classification, NOT on the tunnel's own resolver-query
    /// carve-out (`.encapsulateOwnResolverQuery`), a forced handshake, or a drained packet whose
    /// original classification is no longer known. It is the DEMAND HALF of the egress-dead
    /// predicate (see ``ChainedOutageDriver``): a chain whose WireGuard link is healthy but whose
    /// upstream stopped forwarding to the internet answers keepalives forever while delivering no
    /// non-DNS bytes, and only the user actually ASKING for general traffic distinguishes that
    /// dead chain from an idle-but-healthy one. Undifferentiated ``sawObligingSend`` cannot: a
    /// DNS-only or handshake-only session sets it, so arming egress-dead detection on it would
    /// surrender a working chain the moment its resolver ticked.
    public var sawObligingNonDNSSend: Bool
    /// The transport is at its outstanding-send bound and has stopped taking bytes.
    ///
    /// Read as a LEVEL rather than an edge, and local rather than remote: it is the one
    /// condition under which no obliging send can be issued at all, so without it a wedged
    /// socket would silence the predicate instead of tripping it.
    public var sendChannelSaturated: Bool

    public init(
        sawAuthenticatedPeerDatagram: Bool = false,
        sawInboundData: Bool = false,
        sawObligingSend: Bool = false,
        sawObligingNonDNSSend: Bool = false,
        sendChannelSaturated: Bool = false
    ) {
        self.sawAuthenticatedPeerDatagram = sawAuthenticatedPeerDatagram
        self.sawInboundData = sawInboundData
        self.sawObligingSend = sawObligingSend
        self.sawObligingNonDNSSend = sawObligingNonDNSSend
        self.sendChannelSaturated = sendChannelSaturated
    }
}

/// How a session tells its owner what happened to it.
///
/// The runner classifies packets and drives one engine; it does not decide what a dead session
/// means, how long to keep trying, or when to give up. Those are one budget's job across many
/// sessions, so they live above this.
public protocol ChainedSessionEvents: AnyObject, Sendable {
    /// This session is over and the runner has stopped driving the engine.
    ///
    /// Reported at most ONCE per runner. The engine keeps producing the same verdict once it
    /// has failed — `handshake.is_expired()` makes every subsequent `update_timers` return
    /// `ConnectionExpired` — so a runner that reported on every occurrence would deliver the
    /// same end at the tick rate, and each delivery would be classified against a budget that
    /// has already moved on.
    ///
    /// Called on the engine queue, and re-entrantly: the runner reaches this from inside its
    /// own outbound and release loops, and from a transport that completes inline. The
    /// implementer must not assume it is the outermost frame.
    func sessionEnded(_ cause: ChainedSessionEndCause)
}
