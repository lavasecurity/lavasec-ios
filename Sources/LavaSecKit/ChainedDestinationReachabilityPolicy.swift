import Foundation

/// What one in-tunnel destination looks like right now, as counted by the data path.
///
/// Deliberately raw: counts and instants, no verdict. The table that produces this observes
/// packets and owns no thresholds; ``ChainedDestinationReachabilityPolicy`` owns the thresholds
/// and observes nothing. Splitting them that way is what lets the judgement have behavioural
/// tests without a data path underneath it.
public struct ChainedDestinationObservation: Equatable, Sendable {
    /// Packets sent INTO the tunnel addressed to this destination.
    public let sentPacketCount: UInt64
    /// Packets delivered OUT of the tunnel sourced from this destination.
    public let receivedPacketCount: UInt64
    /// When the currently-open unanswered window was anchored, or `nil` when no window is open
    /// because a receipt closed it. Re-anchored — not merely extended — when a send follows a
    /// lapse in demand; see ``ChainedDestinationReachabilityPolicy/demandContinuitySeconds``.
    public let firstUnansweredSendAtSeconds: Int?
    /// The most recent send to this destination, or `nil` if it has never been sent to. This is
    /// the demand half: without it a window opened once would accumulate across idle time.
    public let lastSendAtSeconds: Int?
    /// Sends since the CURRENT window was anchored — not the lifetime total. Reset by a receipt and
    /// by a re-anchor, so it measures the demand behind THIS wait rather than the destination's
    /// history. It is what separates a retransmitting connection from a single stray packet.
    public let sendsInCurrentWindow: UInt64

    /// Memberwise. The table builds these; tests build them directly, which is the point of
    /// keeping the judgement free of the data path.
    public init(
        sentPacketCount: UInt64,
        receivedPacketCount: UInt64,
        firstUnansweredSendAtSeconds: Int?,
        lastSendAtSeconds: Int?,
        sendsInCurrentWindow: UInt64 = 0
    ) {
        self.sentPacketCount = sentPacketCount
        self.receivedPacketCount = receivedPacketCount
        self.firstUnansweredSendAtSeconds = firstUnansweredSendAtSeconds
        self.lastSendAtSeconds = lastSendAtSeconds
        self.sendsInCurrentWindow = sendsInCurrentWindow
    }
}

/// What this layer is willing to say about ONE destination behind the chain.
///
/// Four cases rather than three, because "we are sending and nothing has come back yet" is
/// neither idle nor answering, and calling it either would be a lie in a type whose entire
/// purpose is to stop the tunnel claiming health it cannot see. ``awaiting(seconds:)`` is the
/// ordinary state of any connection during its first round trip; only ``unanswered(seconds:)``
/// is a complaint.
public enum ChainedDestinationReachability: Equatable, Sendable {
    /// Nobody is asking. Either nothing was ever sent here, or the asking lapsed — idle time is
    /// not a fault, so it is not counted as one.
    case idle
    /// This destination has answered since the last time we started waiting on it.
    case answering
    /// Sustained demand, nothing back yet, still inside the threshold. Not a complaint.
    case awaiting(seconds: Int)
    /// Sustained demand for at least ``ChainedDestinationReachabilityPolicy/unansweredThresholdSeconds``
    /// and not one packet back. The reportable state.
    case unanswered(seconds: Int)
}

/// Decides whether ONE destination behind a chained tunnel is answering.
///
/// ## Why per-destination exists at all
///
/// A split-tunnel chained session had no forwarding-health signal, and its one forwarding
/// counter was not a forwarding counter. Two correct decisions composed into that hole:
/// PR #558 empties `resolverSourceAddresses` in split tunnel (there DNS is often the only
/// captured traffic, and excluding it would starve the connect gate), so the DNS-reply exclusion
/// excludes nothing and `forwardedNonDNSByteCount` counts DNS replies; PR #567 then confined the
/// egress-dead arm to `.fullTunnel`, because a flat aggregate is not proof of dead egress when
/// the runner is still carrying the configured `AllowedIPs` traffic.
///
/// The field capture that forced this (2026-08-27 06:04, build `1787806128`, split tunnel over a
/// Tailscale conf with `AllowedIPs = 100.64.0.0/10` and `DNS = 100.100.100.100`) shows both at
/// once: total connection failure to the one host the user wanted, `hasHandshake true`, zero
/// outages, and `rxBytes == forwardedNonDNSByteCount == 338311` — because the resolver sits
/// INSIDE the claimed range, so every DNS reply landed in the "forwarding" figure. The panel said
/// healthy throughout. A session eleven minutes later, byte-identical, worked perfectly.
///
/// Raising the aggregate's fidelity cannot close this. The question is not "is the chain
/// forwarding" but "is THIS destination answering" — and in that capture the range was carrying
/// traffic while the wanted host was silent. Any range-scoped or session-scoped counter reads
/// healthy in exactly that case, which is the case that matters: a split tunnel's claimed range
/// is usually a whole tailnet, and one node being down is ordinary.
///
/// Per-destination also sidesteps the DNS contamination without touching
/// `resolverSourceAddresses`: the resolver is one row and the wanted host is another. No
/// exclusion set, nothing for PR #558's reasoning to conflict with.
///
/// ## What this is NOT (`INV-CHAIN-6`)
///
/// REPORT only. It never feeds `ChainedEstablishmentPolicy`, never declares an outage, never
/// surrenders, never influences the connect decision. PR #558's and PR #567's reasons are about
/// GATING and do not reach a read-only signal — which is also why the egress-dead declaration
/// stays confined to `.fullTunnel` while this computes for both routing policies. That confinement
/// is not restated here as a pin, because it is already asserted where it lives:
/// `ChainedOutageDriverTests.testASplitTunnelNeverDeclaresAnEgressDeadOutage` must keep passing
/// UNMODIFIED as this signal is wired up, which is what proves the wiring changed no gating.
///
/// It is also not a prober: no synthetic packets. It reads traffic the user already generated,
/// exactly as the egress-dead arm does.
public enum ChainedDestinationReachabilityPolicy {
    /// How long a destination under sustained demand may answer nothing before it is reported.
    ///
    /// `ChainedOutageDriver.egressDeadThresholdSeconds`, deliberately reused rather than tuned
    /// down. The derivation is the same and it is about the ENGINE, not about the consumer: a
    /// chain that just lost forwarding may still recover on the engine's own fresh handshake at
    /// `KEEPALIVE_TIMEOUT + REKEY_TIMEOUT` (15 s) plus one lost-datagram allowance
    /// (`REKEY_TIMEOUT`, 5 s), and a floor under that reports a recovery already in flight as a
    /// fault. A reporting signal could in principle be quicker than one that tears a tunnel down,
    /// but "quicker" here buys a few seconds of headline at the cost of telling the user their
    /// host is dead while WireGuard is mid-rekey — and the user's remedy (restart the VPN) is
    /// precisely the thing that would destroy the recovery.
    /// pinned: ChainedDestinationReachabilityPolicyTests.testTheThresholdMatchesTheEgressDeadDerivation
    public static let unansweredThresholdSeconds = 21

    /// How long the user may go without sending to a destination before its window LAPSES.
    ///
    /// `ChainedOutageDriver.egressDeadDemandContinuitySeconds`, reused for its derivation too:
    /// well under ``unansweredThresholdSeconds`` so a lapse always resets the window before it
    /// could report, and comfortably above a stalled connection's within-window retransmit
    /// backoff (a dead destination the user is actively loading retransmits SYNs at ~1/2/4/8 s,
    /// so its largest gap inside the window is ~8 s). Sustained demand keeps the window alive; a
    /// pause of this length lapses it.
    ///
    /// Erring short is the safe direction HERE for a different reason than in the driver. There a
    /// lapse prevents surrendering a healthy idle chain; here it prevents telling a user that a
    /// host they stopped using is unreachable, which is both unfalsifiable and useless.
    public static let demandContinuitySeconds = 10

    /// How many sends inside the current window make it SUSTAINED demand rather than a stray packet.
    ///
    /// This exists because the lapse guard alone was hiding the very failure this type reports.
    /// A stalled TCP connect retransmits at roughly 1/2/4/8 s, so with sends at 0/1/3/7/15 the
    /// window crossed the threshold at 21 s — and then `lastSend` was 15, so the lapse fired at 25
    /// and turned it back to ``ChainedDestinationReachability/idle``. The next retransmit around 31
    /// re-anchored the window because its gap exceeded ``demandContinuitySeconds``, and every later
    /// backoff gap is longer still, so a permanently failing host reported for a three-second
    /// window and then never again. The shipping mirror samples at ~60 s, so it saw none of it
    /// (Codex P2, PR #593).
    ///
    /// The fix has two halves and this constant is the hinge: a QUALIFIED window — past the
    /// threshold, with at least this many sends behind it — is neither lapsed by the policy nor
    /// re-anchored by the table, so it stays reportable until a receipt clears it. Three, because
    /// a single stray packet is one and any retransmitting connection has passed three well before
    /// the threshold; it separates the two cases with room on both sides.
    /// pinned: ChainedDestinationReachabilityPolicyTests.testASustainedFailureStaysReportableThroughBackoff
    public static let sustainedSendFloor: UInt64 = 3

    /// Judge one destination.
    ///
    /// The send floor applies ONLY to the qualified case. Below the threshold the lapse still
    /// governs, so a stray packet followed by silence is idle within ``demandContinuitySeconds``
    /// and can never become a complaint.
    ///
    /// - Parameters:
    ///   - observation: the destination's raw counts and instants.
    ///   - now: the current reading of the same monotonic clock the observation's instants came
    ///     from (`ChainedMonotonicClock`, an uptime base that does not advance during sleep — so a
    ///     device asleep for an hour does not wake up reporting an hour of silence).
    public static func verdict(
        for observation: ChainedDestinationObservation,
        atSeconds now: Int
    ) -> ChainedDestinationReachability {
        guard let lastSend = observation.lastSendAtSeconds else { return .idle }
        // A receipt closed the window. Nothing to say until the next send re-opens one.
        guard let since = observation.firstUnansweredSendAtSeconds else { return .answering }
        let waited = max(0, now - since)
        // QUALIFIED: past the threshold with sustained demand behind it. Reported regardless of the
        // lapse, because a connection in TCP backoff has gaps longer than `demandContinuitySeconds`
        // by design — treating those as "the user stopped asking" is what made a permanent failure
        // visible for three seconds and then never again. Only a receipt clears this.
        if waited >= unansweredThresholdSeconds,
            observation.sendsInCurrentWindow >= sustainedSendFloor {
            return .unanswered(seconds: waited)
        }
        // The user stopped asking, and this window never qualified. Silence nobody is waiting on is
        // not a fault, and the window is left OPEN rather than cleared — clearing is the table's job
        // on the next send, where it can re-anchor to that send instead of to a question asked
        // minutes ago.
        if now - lastSend >= demandContinuitySeconds { return .idle }
        return waited >= unansweredThresholdSeconds
            ? .unanswered(seconds: waited)
            : .awaiting(seconds: waited)
    }
}
