import Foundation

/// The connect-flow gate's decision: given the latest chained data-path reading and how long the
/// connect has been waiting, is forwarding CONFIRMED, is it UNCONFIRMED after the evidence window,
/// or is the gate still ESTABLISHING?
public enum ChainedEstablishmentOutcome: Equatable, Sendable {
    case establishing
    /// Forwarding is PROVEN. The only verdict that may show "Protected".
    case confirmed
    /// Forwarding is NOT proven within the window. Named for what is true — the chain has not
    /// shown itself carrying traffic — and NOT `.failed`, because nothing necessarily failed:
    /// on a split tunnel an idle tailnet produces this on a perfectly healthy chain. This verdict
    /// describes evidence only; the caller remains responsible for the tunnel lifecycle.
    case unconfirmed
}

/// Gates the chained-connect success signal (the "Protected" surface + success haptic) on the chain
/// actually FORWARDING the user's traffic — bytes coming back from the peer — and withholds that
/// signal when it cannot prove it.
///
/// 🔴 WHAT THIS POLICY DECIDES IS A CLAIM, NOT A LIFECYCLE. It answers "may we say Protected?";
/// the caller separately decides "should this tunnel exist?". PR #628 makes that distinction
/// explicit in the verdict names; the policy itself remains a claim-only primitive. PR #629's app
/// reducer now keeps an unconfirmed tunnel alive and monitors authoritative runtime observations,
/// preserving the unresolved surface until fresh generation-scoped forwarding appears.
///
/// That separation matters because three device connects on 2026-08-30 with `hasHandshake=true`,
/// `outageCount=0` and `channelSendFailEdges=0` had working DNS filtering torn down after no
/// general-traffic byte crossed a chain nobody had asked anything of. On a split tunnel the routed
/// set is the tailnet plus the resolver, so an idle tailnet can produce zero forwarded bytes on a
/// healthy chain. The app leaves "the chain went dead" to the steady-state ladder — link-silence,
/// tunnel-DNS-unserved, egress-dead — which has the demand term this gate lacks.
///
/// This is the third correction of this gate, and the invariant is the point: every weaker signal is
/// true while traffic is NOT reaching the internet through the chain.
/// - the NE's `.connected` status flips when the tunnel PROCESS starts;
/// - the bare WireGuard handshake lands when the peer is merely REACHABLE;
/// - even a DNS lookup RESOLVING through the chain does not prove general forwarding — a chained
///   endpoint can answer its own resolver while dropping (or not NAT-ing) everything else, and a probe
///   that forces a resolution merely MANUFACTURES that false signal. The result was a device fail-open:
///   "Protected" while the exit IP was still the ISP (founder dogfood, PR #558).
///
/// The only signal that means "the chain is carrying your traffic" is received bytes: the peer relayed
/// data back to us over the WireGuard session. So "Protected" requires a positive received-byte delta,
/// and anything short of it — an unknown reply, a handshake with no data, a non-forwarding upstream —
/// stays ESTABLISHING and then resolves UNCONFIRMED. It cannot claim Protected without forwarding
/// evidence, so it cannot fail open. The app's reducer shares the timeout and threshold below; the
/// DNS-only path has no chain to wait for and is confirmed by authoritative runtime mode.
public enum ChainedEstablishmentPolicy {
    /// How long the connect SURFACE waits before it stops saying "Establishing…". WireGuard retries a
    /// lost handshake every `REKEY_TIMEOUT` (5 s) up to `REKEY_ATTEMPT_TIME` (90 s); 90 s is far too
    /// long to hold a user at a connect spinner, so we cap at three handshake attempts (3 × 5 s).
    /// Tunable — not a protocol constant. It bounds the policy's evidence window, not the tunnel's
    /// life. PR #629's lifecycle reducer continues observing after this window and promotes only
    /// from fresh generation-scoped forwarding evidence.
    public static let defaultTimeoutSeconds: TimeInterval = 15

    /// The minimum forwarded non-DNS bytes (since the connect began, within one session generation)
    /// that confirm "the chain is carrying general traffic".
    ///
    /// ONE, because the signal it gates is already filtered. `forwardedNonDNSByteCount` increments
    /// ONLY for a fully-decapsulated inner packet that passed the peer's AllowedIPs and that is NOT a
    /// DNS reply from the tunnel's own resolver — excluded by source address AND transport port 53, so
    /// a resolver IP that also serves ordinary traffic still counts its non-DNS bytes (provider /
    /// `ChainedSessionRunner`, `ChainedInboundDNSReply`). WireGuard control-plane — the handshake
    /// (~92 B) and keepalives (~32 B) — is engine-level and never delivered, and DNS replies are
    /// excluded, so a positive value is BY CONSTRUCTION real general-traffic forwarding from the
    /// internet. A larger floor would false-close a healthy connection whose only early response is
    /// small — a TCP SYN-ACK, an HTTP 204 — under 1 KB yet already proof (Codex, PR #558). A dead or
    /// DNS-only-forwarding chain never delivers such a packet, so it stays at 0 and cannot be
    /// confirmed: the evidence property is unchanged, now with no minimum-size gap.
    public static let forwardingConfirmedByteThreshold: UInt64 = 1

    /// Evaluate the connect gate.
    ///
    /// - Parameters:
    ///   - isChained: the tunnel's mode from the reply. `false` = DNS-only (no chain to wait for →
    ///     already established). `nil` = unknown reply (keep waiting until the timeout).
    ///   - receivedByteDelta: bytes received from the peer over the WireGuard session SINCE the connect
    ///     began (the caller differences the cumulative count within one session generation, resetting
    ///     the baseline on a reconnect). This is the only evidence the chain is actually carrying
    ///     traffic — the peer relayed data back. `nil` = unknown reply (keep establishing).
    ///   - elapsedSeconds: how long the connect has been establishing.
    ///   - timeoutSeconds: the cap after which an un-evidenced chained connect resolves UNCONFIRMED.
    public static func outcome(
        isChained: Bool?,
        receivedByteDelta: UInt64?,
        elapsedSeconds: TimeInterval,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) -> ChainedEstablishmentOutcome {
        // DNS-only: there is no chain to wait for — the tunnel being up IS the connect.
        if isChained == false {
            return .confirmed
        }
        // The peer relayed real data back to us — the chain is carrying traffic. That, not a handshake
        // and not a DNS answer, is the faithful "connected".
        if let receivedByteDelta, receivedByteDelta >= forwardingConfirmedByteThreshold {
            return .confirmed
        }
        // No forwarding proven within the window: withhold confirmation so the policy never certifies
        // a chain that has not carried traffic. The caller decides the lifecycle consequence. An
        // unknown (nil) reply counts as still-establishing until the cap.
        if elapsedSeconds >= timeoutSeconds {
            return .unconfirmed
        }
        return .establishing
    }

    /// The received-byte delta since the connect began, maintaining a per-generation baseline.
    ///
    /// The engine's byte totals reset to 0 whenever the WireGuard session is rebuilt (a reconnect
    /// mid-connect), and its `sessionGeneration` bumps with it. Because the reset and the bump are
    /// coupled, a newly-seen generation's true start is 0 — so the baseline is anchored there, NOT at
    /// the current reading, and the delta counts EVERY byte forwarded since the session began,
    /// including forwarding that arrived before the first poll (~1 s in). Anchoring at the current
    /// reading instead discarded that early window and could false-close a healthy connection that
    /// forwarded its startup traffic and then went idle (Codex, PR #558). It cannot fail open: the
    /// signal is already filtered to delivered non-DNS inner packets, so a non-forwarding (or
    /// DNS-only-forwarding) chain never increments it at all — it stays at 0. Within one generation the
    /// delta is `current - baseline`, clamped at 0 so a spurious counter regression can never read
    /// negative and falsely satisfy the gate. Keeping the pointer logic here (plain integers, no app
    /// types) is what lets it be exercised directly.
    public static func receivedByteDelta(
        currentReceived: UInt64,
        currentGeneration: UInt64,
        baseline: inout (received: UInt64, generation: UInt64)?
    ) -> UInt64 {
        guard let existing = baseline, existing.generation == currentGeneration else {
            baseline = (received: 0, generation: currentGeneration)
            return currentReceived
        }
        return currentReceived >= existing.received ? currentReceived - existing.received : 0
    }

    /// A safe promotion predicate for a caller that elects to observe after the evidence window.
    /// PR #628 only defines this policy surface; it neither schedules that observation nor keeps the
    /// tunnel alive. A later lifecycle consumer may use it to turn `.unconfirmed` into "Protected".
    ///
    /// Deliberately not ``outcome``. That function confirms false as authoritative DNS-only, while
    /// promotion is meaningful only for a path already known to be chained. Current wire replies
    /// preserve chained identity during runner gaps; legacy replies without the lifecycle bit made
    /// false ambiguous, and the runtime adapter keeps those unknown. This narrow helper therefore
    /// still requires explicit chained identity plus a delta meeting the window's same threshold.
    /// pinned: ChainedEstablishmentPolicyTests.testPromotionPredicateRejectsAnUnchainedReply
    public static func promotesAfterWindow(
        isChained: Bool?,
        receivedByteDelta: UInt64?
    ) -> Bool {
        guard isChained == true, let receivedByteDelta else { return false }
        return receivedByteDelta >= forwardingConfirmedByteThreshold
    }
}
