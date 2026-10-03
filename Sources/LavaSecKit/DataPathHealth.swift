import Foundation

/// One window of the tunnel's byte flow: plaintext the engine accepted for encapsulation (tx) and
/// produced by decapsulation (rx) SINCE THE PREVIOUS SAMPLE, plus whether a session is established.
///
/// The provider owns the prior sample and computes these deltas on its own queue (the engine's
/// `statistics()` is engine-queue-confined, `INV-QUEUE-1`); ``DataPathHealth`` reads them as a pure
/// value, holding no baseline itself. Only a single prior sample is retained, never a series, so the
/// signal adds nothing to the NE process's resident footprint (`INV-MEM-1`).
public struct DataPathObservation: Equatable, Sendable {
    /// Plaintext bytes accepted for encapsulation since the previous sample — what we sent.
    public let transmittedByteDelta: UInt64
    /// Plaintext bytes produced by decapsulation since the previous sample — what came back.
    public let receivedByteDelta: UInt64
    /// Whether the engine currently has an established WireGuard session (`timeSinceLastHandshake
    /// != nil`). While chained + connected with NO session, the chain cannot carry traffic, so the
    /// signal reads `.down` — a connect UX is never told "connected" before the upstream is up.
    public let hasHandshake: Bool
    /// Whether this chained session has EVER handshaked. Disambiguates the two states `hasHandshake
    /// == false` conflates (the engine reports nil for "never handshaked, OR expired since"): with
    /// `everHandshaked == false` the tunnel is ESTABLISHING (`.down("tunnel-connecting")`); with
    /// `true` it handshaked and then died — a dead peer, or a keepalive-0 session idle past
    /// `REJECT_AFTER_TIME` — which is a genuine outage (`.down("tunnel-stalled")`), not "connecting".
    /// The provider latches it per session generation. Ignored when `hasHandshake` is true.
    public let everHandshaked: Bool
    /// The longest in-tunnel destination currently under sustained demand with nothing coming back,
    /// in seconds; zero when none is. Sourced from `ChainedDestinationReachabilityPolicy` via the
    /// runner's destination table, NOT from this window's byte deltas.
    ///
    /// The reason it exists beside them: the byte heuristic below is a whole-session aggregate, and
    /// no aggregate can separate "the chain is carrying your traffic" from "the chain is carrying
    /// traffic and the host you want is silent". In a split tunnel the claimed range is usually a
    /// whole tailnet, so one node being down is ordinary — and reads healthy on every aggregate
    /// there is. Defaulted, per this struct's extended-never-reshaped rule.
    public let unansweredDestinationSeconds: Int

    public init(
        transmittedByteDelta: UInt64,
        receivedByteDelta: UInt64,
        hasHandshake: Bool,
        everHandshaked: Bool = false,
        unansweredDestinationSeconds: Int = 0
    ) {
        self.transmittedByteDelta = transmittedByteDelta
        self.receivedByteDelta = receivedByteDelta
        self.hasHandshake = hasHandshake
        self.everHandshaked = everHandshaked
        self.unansweredDestinationSeconds = unansweredDestinationSeconds
    }
}

/// The data-path health signal — the third ``ConnectivityHealthSignal``, and the one that sees what
/// DNS and link health cannot: a peer that stays reachable (DNS still answers, the path is up) but
/// stops FORWARDING general traffic to the internet. That was invisible on device — DNS looked
/// perfect while every page died — because nothing watched the byte flow past the resolver.
///
/// ## The signal
///
/// Traffic that leaves through a forwarding peer comes BACK: a page load is a download, so over any
/// real window `rx` normally dominates `tx`. When the peer stops forwarding, our requests — and the
/// OS's TCP retransmits of the unacknowledged ones — keep `tx` climbing while `rx` stays flat, so
/// `tx` comes to dominate `rx`. That inversion, over a window with real transmit volume, is the
/// tell. It is deliberately coarse: a legitimate bulk UPLOAD also has `tx` dominating `rx` and would
/// read `.down` here — a tolerable false positive because this signal is SURFACE-ONLY. It never
/// drives a reconnect: a flaky or non-forwarding upstream cannot be fixed by restarting the tunnel,
/// and reconnecting on it would reintroduce the false-reconnect churn #548 closed. The supervisor
/// (a later slice) surfaces it to the operator; it never acts on it.
public struct DataPathHealth: ConnectivityHealthSignal {
    public let id: ConnectivityHealthSignalID = .dataPath

    /// Transmit must clearly exceed keepalive/control noise before an asymmetry means anything: a
    /// quiet tunnel (`tx` ~ 0) has nothing to judge, and persistent-keepalive traffic is tiny.
    static let significantTransmitByteFloor: UInt64 = 16_384
    /// Flag when `tx` exceeds this multiple of `rx` over a window that cleared the floor — i.e. the
    /// normal "replies dominate" relationship has inverted hard.
    static let transmitToReceiveDominanceRatio: UInt64 = 4

    /// Locale-independent diagnostic label; a new condition with no `ProtectionConnectivitySeverity`
    /// counterpart, so it names itself rather than borrowing a DNS label.
    public static let upstreamQuietReason = "upstream-quiet"
    /// Chained + connected but the WireGuard session has NEVER handshaked — the tunnel process is up
    /// but the chain is still establishing and cannot yet carry a byte. Distinct from `upstream-quiet`
    /// (peer reachable, not forwarding), `tunnel-stalled` (was up, now dead), and DNS-only (no path).
    public static let tunnelConnectingReason = "tunnel-connecting"
    /// Chained session that handshaked and then EXPIRED — a dead peer, or a keepalive-0 session idle
    /// past `REJECT_AFTER_TIME`. The chain carried traffic and no longer does: a genuine outage, NOT
    /// the establishing state, so a connect gate must never read it as "still connecting".
    public static let tunnelStalledReason = "tunnel-stalled"
    /// A specific in-tunnel destination has been asked for and has answered nothing, while the chain
    /// itself is healthy — filtering fine, DNS fine, the peer forwarding. Distinct from
    /// `upstream-quiet` (the whole peer is not forwarding) because the remedies differ completely:
    /// this one is somebody else's host being down, and telling the user their protection is
    /// impaired would send them to disable the feature that is working.
    ///
    /// REPORT ONLY, structurally. `ConnectivityHealthSupervisor` excludes the ENTIRE data-path
    /// verdict from `recommendedAction` — not this string in particular — so a new reason on this
    /// signal cannot reach `.reconnect` any more than `upstream-quiet` can.
    /// pinned: DataPathHealthTests.testAnUnansweredDestinationIsReportedWithoutAnyRecommendedAction
    public static let destinationUnansweredReason = "destination-unanswered"

    public init() {}

    public func verdict(for inputs: ConnectivityHealthInputs, now: Date) -> HealthVerdict {
        // Off, or DNS-only / no data-path sample yet: there is no data path to judge.
        guard inputs.isConnected, let observation = inputs.dataPath else {
            return .healthy
        }
        // Chained + connected but no established WireGuard session: the process is up but the chain
        // cannot carry a byte. `hasHandshake == false` means "never handshaked, OR expired since"
        // (WireGuardSession), so split the two: never → establishing ("Connecting…"); expired → a
        // genuine outage ("tunnel-stalled"). This replaced the old "no handshake → healthy", which
        // read "Healthy" over the dead first ~10-15 s of a chained connect (founder dogfood, #556).
        guard observation.hasHandshake else {
            return observation.everHandshaked
                ? .down(Self.tunnelStalledReason)
                : .down(Self.tunnelConnectingReason)
        }
        // BEFORE the byte heuristic, because it is strictly better evidence about the same
        // question. The ratio below is a coarse whole-session aggregate that a legitimate bulk
        // upload also satisfies; a destination the user is actively asking for and hearing nothing
        // from is a direct observation, and it is the one case every aggregate here reads healthy
        // in (2026-08-27 field capture). When both would fire, the specific reason is the useful one.
        // pinned: DataPathHealthTests.testTheDestinationReasonWinsOverTheByteRatioHeuristic
        if observation.unansweredDestinationSeconds > 0 {
            return .down(Self.destinationUnansweredReason)
        }
        // Real transmit volume, but rx did not keep up: we are sending (and retransmitting) into a
        // peer that is not forwarding the replies back.
        if observation.transmittedByteDelta >= Self.significantTransmitByteFloor,
            observation.receivedByteDelta * Self.transmitToReceiveDominanceRatio
                < observation.transmittedByteDelta
        {
            return .down(Self.upstreamQuietReason)
        }
        return .healthy
    }
}
