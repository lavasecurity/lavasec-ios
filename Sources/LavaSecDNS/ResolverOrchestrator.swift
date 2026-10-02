import Foundation
import LavaSecKit

// Upstream resolution orchestration, extracted from PacketTunnelProvider:
// transport routing, degradation to plain DNS when an encrypted plan has no
// endpoints, per-endpoint failover with backoff gates, attempt assembly, and
// device-DNS fallback sequencing. Wire-level execution stays behind injected
// executors so the policy is testable with fakes; backoff STATE also stays
// with the caller — the orchestrator only consults the injected gate.

/// Stable per-attempt classification used by retry policy, health scoring, and cross-process diagnostics.
// `CaseIterable` so a classification test can enumerate the outcomes rather than restate them:
// the property worth having is that a NEW case fails an existing test until it is classified on
// purpose, and a hand-written list cannot give that (Codex, PR #622).
public enum ResolverAttemptOutcome: String, CaseIterable, Sendable {
    /// The transport completed with a response matching the query identity.
    case success
    /// The attempt exceeded its configured time budget.
    case timeout
    /// A DoH endpoint responded with a non-success HTTP status.
    case httpStatusFailure = "http-status-failure"
    /// Backoff policy suppressed the endpoint without a wire attempt.
    case backedOff = "backed-off"
    /// The query could not be sent to the selected endpoint.
    case sendFailed = "send-failed"
    /// The endpoint produced no readable or valid response.
    case receiveFailed = "receive-failed"
    /// A configured plain-DNS address was not a valid numeric endpoint.
    case invalidAddress = "invalid-address"
    /// The requested resolver transport is unavailable on this runtime path.
    case unsupported
    /// A UDP or TCP resolver socket could not be created or configured.
    ///
    /// A GENUINE local socket failure — `socket(2)`/timeout-setup/port-claim in `SocketResolvers`, or
    /// a `UDPResolverSocket` initializer failure — distinct from ``tunnelInterfaceUnavailable`` (the
    /// binding-not-ready refusal). Under local resource pressure these can persist, so this one DOES
    /// back off (throttle) — see `ResolverBackoffPolicy` (Codex, PR #570).
    ///
    /// BECAUSE IT THROTTLES, IT MUST MEAN ONLY THIS. The tunnelled executor used to answer it for a
    /// stale-lifecycle or stale-latch token refusal, and for a deallocated provider — three
    /// conditions where no socket is ever reached and nothing is wrong with the endpoint. Field
    /// capture 2026-08-29T08:11Z: three such refusals at cold start benched the profile's SOLE
    /// resolver for 30 s and the next 23 lookups were answered SERVFAIL with the user's alternative
    /// DNS never asked — 23 `backedOff` refusals behind 3 `socketUnavailable` ones.
    /// Those now answer ``refusedAfterLifecycleEnded`` / ``refusedAfterLatchReplaced``, which carry
    /// no penalty and end the ladder. Anything added here later must ask the same question first:
    /// would charging the endpoint for this be a lie?
    case socketUnavailable = "socket-unavailable"
    /// The resolver socket has no tunnel interface to pin to yet: `NEPacketTunnelProvider.virtualInterface`
    /// lags a few seconds after a chained tunnel starts, so `currentResolverSocketBinding()` refuses.
    ///
    /// Split out from ``socketUnavailable`` deliberately: it is a TRANSIENT, LOCAL "can't send yet"
    /// condition — nothing is wrong with the upstream — that clears the instant iOS populates the
    /// interface. Penalising the upstream endpoint for it backed the resolver off for 30 s and produced
    /// a ~30-45 s DNS blackout at connect (device-confirmed 2026-08-23). It must NOT back off (the query
    /// the moment the interface is ready must go straight out), while genuine socket failures still do.
    case tunnelInterfaceUnavailable = "tunnel-interface-unavailable"
    /// The resolver socket has a TUNNEL interface but no PHYSICAL interface to pin to.
    ///
    /// Split out from ``tunnelInterfaceUnavailable`` because the two are opposite conditions that were
    /// reported as one. That one is the startup `virtualInterface` lag — the TUNNEL interface is not
    /// known yet. This one is F2's destination-scoped pin: chained is latched and the tunnel interface IS
    /// known, but the live physical interface index is missing for a destination the DNS capture floor
    /// claimed and the profile does not carry, so the binding refuses rather than let an unbound socket
    /// follow the routing table back into the tunnel's own claim.
    ///
    /// Like its sibling it is a LOCAL decision WE made — nothing was sent and nothing is wrong with the
    /// upstream — so it must not back off or bench the resolver.
    /// pinned: ResolverBackoffPolicyTests.testPhysicalInterfaceUnavailableDoesNotBackOffTheEndpoint
    case physicalInterfaceUnavailable = "physical-interface-unavailable"
    /// OUR OWN port registry refused to name the source port this query would carry.
    ///
    /// Split out of ``socketUnavailable`` for the reason ``tunnelInterfaceUnavailable`` was: it is
    /// not a socket failure and not the resolver's fault, it is our bookkeeping declining. The
    /// kernel would have given us the socket; `ChainedResolverPortRegistry` would not give us the
    /// carve-out, so we refuse rather than send a datagram the classifier would re-resolve.
    ///
    /// MUST NOT BACK OFF, for the same reason as its two siblings — charging the upstream for our
    /// own table being full is the category error this family keeps making. Device 2026-08-29
    /// proved the conflation was not theoretical: `refusedAtCapacity` matched `socketUnavailable`
    /// exactly (7 of 7), so every "socket failure" that session was in fact this, and the honest
    /// remedy was to fix the table rather than to throttle a healthy resolver.
    /// pinned: ResolverBackoffPolicyTests.testTokenRefusalsDoNotThrottleTheEndpoint
    /// pinned: TunnelledPlainDNSResolutionTests.testOnlyOutcomesThatProveADatagramWentOutReachTheWire
    case resolverPortUnavailable = "resolver-port-unavailable"
    /// A response arrived FROM THE QUERIED RESOLVER for a different DNS transaction or question.
    ///
    /// Source-matched by construction, which is what makes it evidence: the query reached the
    /// resolver and a reply came back, even though this attempt could not use it. Off-source
    /// datagrams are ``unexpectedSourceResponse`` and prove nothing (PR #577).
    case mismatchedResponse = "mismatched-response"
    /// A datagram arrived from an address or port other than the queried resolver's.
    ///
    /// Not evidence about the resolver OR the path to it — it is unsolicited traffic that
    /// happened to reach the socket. Distinct from ``mismatchedResponse`` for exactly that
    /// reason: the two were one outcome, and a chained fallback receiving source-matched
    /// mismatches was reported as a peer that had forwarded nothing (PR #577).
    case unexpectedSourceResponse = "unexpected-source-response"
    /// Device DNS was selected but no captured resolver address was available.
    case deviceDNSUnavailable = "device-dns-unavailable"
    /// The egress policy refused this transport; no wire attempt was made.
    ///
    /// A DELIBERATE refusal, and it needs its own outcome for two reasons. It must not read as
    /// a failure of the resolver — nothing was wrong with it, and chained mode is working as
    /// designed. And it must not read as SUCCESS, which is what an empty `attempts` array
    /// produced: `failureSummary` is `attempts.last?.outcome.rawValue`, so no attempts meant
    /// nil, and the smoke-probe log renders `failureSummary ?? "success"`. A refusal that
    /// prevents a DNS leak was being logged as a successful resolution.
    case refusedByEgressPolicy = "refused-by-egress-policy"
    /// The tunnel session this resolution began under has ended; no wire attempt was made.
    ///
    /// Its own outcome rather than a reuse of `refusedByEgressPolicy`, because the two answer
    /// different questions and a reader diagnosing a log needs to know which: one says "this
    /// transport may not egress here", the other says "whoever asked is gone". Folding them
    /// together would make a stale-lifecycle refusal indistinguishable from chained mode
    /// working as designed.
    ///
    /// It shares that one's CLASSIFICATION everywhere — see ``isDeliberateRefusal`` — because
    /// on the only question health scoring asks, they agree completely: nothing was wrong
    /// with the resolver.
    case refusedAfterLifecycleEnded = "refused-after-lifecycle-ended"
    /// The DATA PATH this work was admitted under was replaced while it was in flight.
    ///
    /// DISTINCT FROM ``refusedAfterLifecycleEnded``, and the distinction is the point: the tunnel
    /// session is still very much alive here. What changed is the latch inside it — the user
    /// altered their resolver or their fallback policy — so a rung admitted under the old one may
    /// no longer egress. Reporting that as "the lifecycle ended" would send whoever reads a field
    /// capture looking for a tunnel restart that never happened.
    case refusedAfterLatchReplaced = "refused-after-latch-replaced"
    /// The lookup expired before sending; it ends the ladder without charging the endpoint.
    case expiredBeforeSend = "expired-before-send"
    /// A tunnel-carried answer arrived with the TC bit set and was not relayed (S6).
    ///
    /// Its own outcome because it is neither: the resolver ANSWERED — promptly and
    /// correctly — that the response does not fit UDP, so the query provably reached the
    /// upstream through the tunnel and came back. Resolved decision 3 makes that resolver
    /// LIVENESS, never failure — counting it as failure would let one large-response
    /// domain, retried by a browser, spend the outage budget and surrender chaining
    /// feature-wide. The client's answer is the fail-closed SERVFAIL synthesized from the
    /// nil response; the TC answer itself is never relayed, because the stub's TCP retry
    /// is a flow the tunnel deliberately does not serve in v1.
    case truncatedAnswer = "truncated-answer"

    /// True for outcomes that record a decision WE made, not anything a resolver did.
    ///
    /// A CATEGORY rather than a list repeated at each site, because the list grew and the
    /// repetition is what would rot: health scoring, backoff mapping and evidence
    /// classification each held their own `== .refusedByEgressPolicy`, so adding a second
    /// refusal would have been scored as a resolver failure at every one of them — an
    /// endpoint benched, and the escalation ladder advanced, for a tunnel that merely
    /// stopped.
    ///
    /// Exhaustive on purpose, with no `default`: a new outcome must be classified here
    /// deliberately rather than defaulting into "the resolver misbehaved".
    public var isDeliberateRefusal: Bool {
        switch self {
        case .refusedByEgressPolicy, .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced, .expiredBeforeSend,
            .tunnelInterfaceUnavailable, .physicalInterfaceUnavailable, .resolverPortUnavailable:
            // `.tunnelInterfaceUnavailable` is a decision we made too: the tunnel interface is not
            // bound yet, so we refuse to send rather than attempting — nothing is wrong with the
            // resolver, so it must not be benched or advance the escalation ladder (Codex, PR #570).
            // `.physicalInterfaceUnavailable` is its opposite-hand sibling: the tunnel interface is
            // known, but the physical pin F2 needs is missing, so we refuse the same way.
            // `.resolverPortUnavailable` is the same shape one layer down: the kernel would have
            // given us the socket, our own registry declined the carve-out.
            return true
        case .success,
            .timeout,
            .httpStatusFailure,
            .backedOff,
            .sendFailed,
            .receiveFailed,
            .invalidAddress,
            .unsupported,
            .socketUnavailable,
            .mismatchedResponse,
            .unexpectedSourceResponse,
            .deviceDNSUnavailable,
            .truncatedAnswer:
            return false
        }
    }

    /// True for the refusals that END A LADDER rather than failing one rung of it.
    ///
    /// An ended session, replaced path, or spent deadline cannot admit another rung.
    /// The refusal stays last in `attempts`, keeping unsent work neutral for resolver health.
    ///
    /// A CATEGORY RATHER THAN AN EQUALITY TEST AT EACH LADDER, because there are four such tests
    /// across the plain/device ladders alone and another refusal added later would have to find
    /// every one of them. It found exactly this problem when `.refusedAfterLatchReplaced` was
    /// added (PR #610).
    /// pinned: TunnelledPlainDNSResolutionTests.testOnlyOutcomesThatProveADatagramWentOutReachTheWire
    public var endsTheResolutionLadder: Bool {
        switch self {
        case .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced, .expiredBeforeSend:
            return true
        case .success, .timeout, .httpStatusFailure, .backedOff, .sendFailed, .receiveFailed,
            .invalidAddress, .unsupported, .socketUnavailable, .mismatchedResponse,
            .unexpectedSourceResponse, .deviceDNSUnavailable, .truncatedAnswer,
            .refusedByEgressPolicy, .tunnelInterfaceUnavailable, .physicalInterfaceUnavailable,
            .resolverPortUnavailable:
            // `.resolverPortUnavailable` deliberately does NOT end the ladder: the registry drains
            // on its own, so the next address — or the retry one layer up — may well succeed where
            // this attempt did not. It is transient in a way the two lifecycle refusals are not.
            return false
        }
    }

    /// A LOCAL failure that could plausibly have cleared by the time a retry lands.
    ///
    /// AN ALLOWLIST, NOT A CARVE-OUT, and the direction is the point. The first version of the
    /// retry asked the opposite question — "does this refusal end the ladder?" — and treated
    /// everything else as retryable. That silently swept in the CONFIGURATION-INVARIANT refusals:
    /// ``refusedByEgressPolicy`` is derived from the latched egress allowance, so it reproduces
    /// itself exactly, and retrying it added ~80 ms to every fail-closed answer while holding one
    /// of the eight bounded resolver slots for the duration — a burst of them stalling unrelated
    /// DNS work (Codex, PR #622).
    ///
    /// The three that qualify share one shape: the local resource was momentarily unavailable and
    /// nothing about the request was wrong. A descriptor the kernel has not released, a send that
    /// hit transient buffer pressure, a port table that drains on its own. Everything else is
    /// either a decision we made (policy, lifecycle, latch), a fact about the configuration
    /// (invalid address, unsupported transport), or a condition measured in seconds rather than
    /// milliseconds (``tunnelInterfaceUnavailable``'s interface lag, ``backedOff``'s 30 s penalty)
    /// — a 40 ms retry cannot outlast either, so spending one is pure latency.
    ///
    /// EXHAUSTIVE with no `default`, like every predicate on this type: a new outcome must be
    /// classified here on purpose. Defaulting to retryable is how the egress-policy refusal got
    /// in; defaulting to not-retryable at least fails in the direction of answering promptly.
    /// pinned: ResolverOrchestratorTests.testOnlyTransientLocalFailuresAreWorthRetrying
    public var isTransientLocalFailure: Bool {
        switch self {
        case .sendFailed, .socketUnavailable, .resolverPortUnavailable:
            return true
        case .success, .timeout, .httpStatusFailure, .backedOff, .receiveFailed,
            .invalidAddress, .unsupported, .mismatchedResponse, .unexpectedSourceResponse,
            .deviceDNSUnavailable, .truncatedAnswer, .refusedByEgressPolicy,
            .tunnelInterfaceUnavailable, .physicalInterfaceUnavailable,
            .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced, .expiredBeforeSend:
            return false
        }
    }

    /// True for outcomes that PROVE a datagram left this device.
    ///
    /// The question any FORWARDING claim has to answer first. "Did the far end forward our query?"
    /// is only askable about a query that was actually sent — a rung that failed locally says
    /// nothing about the peer, and reporting it as forwarding evidence accuses a machine that was
    /// never contacted.
    ///
    /// This is the same rule resolver-health scoring already applies (local failures are not
    /// resolver evidence), stated as a category so it cannot be re-derived differently at each
    /// site — the exact rot ``isDeliberateRefusal`` was extracted to stop.
    ///
    /// It matters most at chained connect. ``tunnelInterfaceUnavailable`` fires for seconds while
    /// `virtualInterface` lags a fresh tunnel, so without this the T1 panel would count those
    /// local refusals as attempts and, after three, tell the user their VPN was not forwarding and
    /// send them to configure an exit node they do not need (Codex, PR #575).
    ///
    /// Exhaustive on purpose, with no `default`: a new outcome must be classified here
    /// deliberately rather than defaulting into "a datagram went out".
    ///
    /// pinned: TunnelledPlainDNSResolutionTests.testOnlyOutcomesThatProveADatagramWentOutReachTheWire
    public var reachedTheWire: Bool {
        switch self {
        // Something came back, or we waited for something that never did — either way the query
        // was on the wire. `.timeout` and `.receiveFailed` are the whole point: silence AFTER a
        // send is exactly the forwarding failure the panel exists to report.
        case .success, .truncatedAnswer, .timeout, .receiveFailed, .mismatchedResponse,
            .unexpectedSourceResponse, .httpStatusFailure:
            return true
        // Nothing was sent: we refused, we could not build a socket, we had no interface to pin
        // to, the address was not an endpoint, or the send itself failed.
        case .backedOff, .sendFailed, .invalidAddress, .unsupported, .socketUnavailable,
            .tunnelInterfaceUnavailable, .physicalInterfaceUnavailable,
            .resolverPortUnavailable, .deviceDNSUnavailable,
            .refusedByEgressPolicy, .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced, .expiredBeforeSend:
            return false
        }
    }

    internal init(_ outcome: DNSTransportOutcome) {
        switch outcome {
        case .success:
            self = .success
        case .timeout:
            self = .timeout
        case .httpStatusFailure:
            self = .httpStatusFailure
        case .sendFailed:
            self = .sendFailed
        case .receiveFailed:
            self = .receiveFailed
        case .mismatchedResponse:
            self = .mismatchedResponse
        case .unexpectedSourceResponse:
            self = .unexpectedSourceResponse
        case .expiredBeforeSend:
            self = .expiredBeforeSend
        case .refusedAfterLatchReplaced:
            // The same refusal the plain and device seams produce (PR #610), reached through the
            // encrypted transports' own send seam. `endsTheResolutionLadder` therefore stops the
            // endpoint walk on it, and `reachedTheWire` keeps it out of the panel's attempt count.
            self = .refusedAfterLatchReplaced
        }
    }
}

/// One ordered resolver attempt, including the endpoint label and transport metadata exposed in tunnel diagnostics.
public struct ResolverAttempt: Sendable {
    /// Resolver endpoint identifier or address recorded for this attempt.
    public let address: String
    /// Classified result consumed by fallback and backoff policy.
    public let outcome: ResolverAttemptOutcome
    /// Effective transport used for this attempt; public clients receive read-only access after construction.
    public private(set) var transport: DNSResolverTransport
    internal var usedTCP: Bool
    /// Negotiated HTTP protocol observed for a DoH attempt, including failed outcomes when metrics were available.
    public private(set) var negotiatedDoHProtocol: String?
    /// The provider's path epoch captured when this attempt was sent.
    ///
    /// Tunnelled attempts use it to fence endpoint backoff across a surviving-carry roam
    /// (PR #565). Physical Device DNS uses the same send-time identity to prevent recapture
    /// from acting on a failure from the network preceding a handoff.
    public let pathEpoch: Int?
    /// Actual destination-specific egress, when the executor supplies it.
    public let actualEgress: DNSResolverTierHealthSnapshot.Egress?
    /// Provider observation order captured immediately before an actual Device DNS send.
    /// Missing stamps cannot establish an independent confirmation attempt.
    public let sendSequence: UInt64?
    /// Raw reply order observed before a later TCP retry or endpoint can delay this leg.
    public private(set) var replySequence: UInt64?

    /// Records one attempt; `usedTCP` is retained only for DNS-internal assembly compatibility.
    public init(
        address: String,
        outcome: ResolverAttemptOutcome,
        transport: DNSResolverTransport = .plainDNS,
        usedTCP: Bool = false,
        negotiatedDoHProtocol: String? = nil,
        pathEpoch: Int? = nil,
        actualEgress: DNSResolverTierHealthSnapshot.Egress? = nil,
        sendSequence: UInt64? = nil,
        replySequence: UInt64? = nil
    ) {
        self.address = address
        self.outcome = outcome
        self.transport = transport
        self.usedTCP = usedTCP
        self.negotiatedDoHProtocol = negotiatedDoHProtocol
        self.pathEpoch = pathEpoch
        self.actualEgress = actualEgress
        self.sendSequence = sendSequence
        self.replySequence = replySequence
    }

    /// Records a source-matched reply; an absent observation retains any existing stamp.
    public func recordingReply(observationSequence: UInt64?) -> Self {
        guard let observationSequence else { return self }
        var copy = self
        copy.replySequence = observationSequence
        return copy
    }
}

/// Aggregate result of primary and optional fallback resolution, with attempts retained in execution order.
public struct DNSResolutionResult: Sendable {
    /// DNS response bytes selected for the caller; a failed encrypted fallback may replace a primary packet with `nil`.
    public let response: Data?
    /// Resolver identifier retained during combination; it may remain non-`nil`
    /// when an encrypted fallback leaves `response` nil.
    public let successfulResolverAddress: String?
    /// Every attempted or backoff-suppressed endpoint in execution order.
    public let attempts: [ResolverAttempt]
    /// Transport associated with the final selected result.
    public let transport: DNSResolverTransport
    /// Whether a UDP reply carried the DNS truncated bit and required TCP consideration.
    public let udpTruncated: Bool
    /// Whether plain-DNS resolution attempted TCP after UDP truncation.
    public let tcpFallbackAttempted: Bool
    /// Whether the TCP fallback produced the selected response.
    public let tcpFallbackSucceeded: Bool
    /// Whether the resolver sequence reached the captured Device-DNS fallback route.
    public private(set) var deviceDNSFallbackAttempted: Bool
    /// Whether Device-DNS fallback produced the selected response.
    public private(set) var deviceDNSFallbackSucceeded: Bool
    /// Whether Device DNS could not run because no captured resolver was available.
    public private(set) var deviceDNSUnavailable: Bool
    // Set when the encrypted (Quad9 DoH) fallback produced this response because
    // a Device-DNS primary was wedged. Observable so the provider can log/diagnose
    // that the fallback engaged; distinct from the device-DNS-fallback flags.
    /// Whether an encrypted fallback, rather than the Device-DNS primary, produced the selected response.
    public private(set) var usedEncryptedFallback: Bool
    /// End-to-end resolver duration in rounded milliseconds, or `nil` until timing is recorded.
    public private(set) var durationMilliseconds: Int?

    /// This resolution produced no response AND no datagram ever left the device.
    ///
    /// THE POINT OF THE PREDICATE IS WHAT IT LICENSES THE CALLER NOT TO SAY. `SERVFAIL` is a claim
    /// — "the DNS system tried to resolve this name and failed" — and when nothing was sent, that
    /// claim is false: we learned nothing about the name, only about ourselves. A stub cannot tell
    /// the two apart, so it takes our local condition as a fact about the server and stops asking.
    /// A browser does exactly that with a sub-resource: the page loads and the video never appears
    /// (field, 2026-08-29).
    ///
    /// `reachedTheWire` is the same bar the T1 rung's admission uses
    /// (``ResolverOrchestrator/upstreamDeclinedToServe``), deliberately — a resolution that may not
    /// open the fallback because it never asked the upstream is exactly a resolution that may not
    /// report the upstream as broken. One fact, one predicate, two consumers.
    ///
    /// An EMPTY attempt list satisfies this, and correctly: no attempts is no datagrams.
    /// pinned: ResolverOrchestratorTests.testARefusalBeforeTheWireIsNotAnAnswer
    public var wasRefusedBeforeTheWire: Bool {
        response == nil && !attempts.contains { $0.outcome.reachedTheWire }
    }

    /// The refusal above, and retrying it could plausibly do something.
    ///
    /// TWO CONDITIONS, and neither implies the other. At least one attempt must be a transient
    /// local failure (``ResolverAttemptOutcome/isTransientLocalFailure``) — otherwise there is
    /// nothing for a retry to catch — and NO attempt may end the ladder
    /// (``ResolverAttemptOutcome/endsTheResolutionLadder``), because a ladder that ended on a dead
    /// lifecycle or a replaced latch reproduces that refusal exactly however transient an earlier
    /// rung's failure was. A ladder can carry both: a `.sendFailed` on the first address followed
    /// by `.refusedAfterLifecycleEnded` on the second is a resolution whose session is gone.
    /// pinned: ResolverOrchestratorTests.testALadderEndingRefusalIsNotWorthRetrying
    /// pinned: ResolverOrchestratorTests.testOnlyTransientLocalFailuresAreWorthRetrying
    public var isWorthRetryingBeforeTheWire: Bool {
        wasRefusedBeforeTheWire
            && !attempts.contains { $0.outcome.endsTheResolutionLadder }
            && attempts.contains { $0.outcome.isTransientLocalFailure }
    }

    /// What the chained T1 rung did, or `nil` when no rung ran.
    ///
    /// THE ONLY WAY THE RUNG'S OUTCOME LEAVES THE PACKAGE, and since the tunnelled route stopped
    /// carrying a T1 set the only source of T1 evidence at all. The provider used to read
    /// the chained fallback counters off the tunnelled T0 verdict; that verdict has carried no
    /// T1 since PR #590, and the terms it derived them from are deleted. Without this, every
    /// physical rung — successful rescues included — would leave `chainedFallbackAttemptCount` and
    /// its siblings at zero: the panel stuck on "Ready — not needed yet", and the field telemetry
    /// that is supposed to VALIDATE this feature measuring nothing (Codex, PR #590).
    ///
    /// `nil` also covers a rung that never reached the wire — refused by the allowance, or a plan
    /// with nowhere to send. Nothing was queried, so nothing may be counted as an attempt; that
    /// is the same bar `TunnelledPlainDNSResolution` applies to T0 (`reachedTheWire`), and it
    /// exists because counting local refusals once had the panel blaming the peer for queries it
    /// had never been sent (PR #575).
    public let tierOneRung: ResolverOrchestrator.TierOneRungEvidence?

    /// What the T1 rung's OWN SELECTED RESOLVER did, captured before any fallback leg of the
    /// rung's ladder merged into this result. `nil` on every `.planned` resolution.
    ///
    /// THE WHOLE LADDER IS THE WRONG SUBJECT for the chained fallback counters, and reading it as
    /// the right one was a fail-open in the panel. Since PR #596 the rung runs the FULL ladder
    /// (`INV-CHAIN-7`), so `rung.response` can come from the rung's device-DNS or encrypted
    /// fallback rather than from the resolver the user chose. Judged on the merged result, a
    /// selection that timed out on every query was still counted `.served` the moment a fallback
    /// leg rescued it: `chainedFallbackRescueCount` incremented, both falling streaks reset, and
    /// the panel rendered `.working(rescues:)` for a resolver that had answered NOTHING. The two
    /// verdicts that name the real failures — `.notForwarded` and `.answeringWithoutResolving` —
    /// became unreachable for exactly the user who needed them (PR #606).
    ///
    /// SEPARATE FROM ``tierOneRung`` RATHER THAN DERIVED AT THE MERGE, because the merged result
    /// cannot answer the question. `.served` alone could be recovered from
    /// ``deviceDNSFallbackSucceeded`` and ``usedEncryptedFallback``, but `.answered` vs
    /// `.attempted` cannot: ``attempts`` is the concatenation of the selection's and the fallback
    /// legs', with nothing marking the boundary, so a fallback's reply would read as the
    /// selection's. That distinction is the difference between telling the operator their peer is
    /// not forwarding DNS and telling them their resolver replies but cannot resolve — the two
    /// diagnoses this feature exists to separate.
    ///
    /// Carried through every transformer for the same reason ``tierOneRung`` is: the rung's own
    /// fallback merges and `recordingDuration` all run after it is stamped.
    /// pinned: ResolverOrchestratorTests.testARescueByTheRungsOwnFallbackIsNotCreditedToTheSelection
    public private(set) var tierOneSelectionOutcome: ResolverOrchestrator.TierOneRungOutcome?

    /// Independent evidence for every configured resolver leg, sealed before fallback merging.
    public private(set) var tierEvidence: [ResolverTierEvidence]

    /// Creates a complete result whose fallback and timing fields are read-only to public clients after construction.
    public init(
        response: Data?,
        successfulResolverAddress: String?,
        attempts: [ResolverAttempt],
        transport: DNSResolverTransport,
        udpTruncated: Bool,
        tcpFallbackAttempted: Bool,
        tcpFallbackSucceeded: Bool,
        deviceDNSFallbackAttempted: Bool = false,
        deviceDNSFallbackSucceeded: Bool = false,
        deviceDNSUnavailable: Bool = false,
        usedEncryptedFallback: Bool = false,
        durationMilliseconds: Int? = nil,
        tierOneRung: ResolverOrchestrator.TierOneRungEvidence? = nil,
        tierOneSelectionOutcome: ResolverOrchestrator.TierOneRungOutcome? = nil,
        tierEvidence: [ResolverTierEvidence] = []
    ) {
        self.response = response
        self.successfulResolverAddress = successfulResolverAddress
        self.attempts = attempts
        self.transport = transport
        self.udpTruncated = udpTruncated
        self.tcpFallbackAttempted = tcpFallbackAttempted
        self.tcpFallbackSucceeded = tcpFallbackSucceeded
        self.deviceDNSFallbackAttempted = deviceDNSFallbackAttempted
        self.deviceDNSFallbackSucceeded = deviceDNSFallbackSucceeded
        self.deviceDNSUnavailable = deviceDNSUnavailable
        self.usedEncryptedFallback = usedEncryptedFallback
        self.durationMilliseconds = durationMilliseconds
        self.tierOneRung = tierOneRung
        self.tierOneSelectionOutcome = tierOneSelectionOutcome
        self.tierEvidence = tierEvidence
    }

    /// Diagnostic raw value of the final attempt outcome, or `nil` when no attempt was recorded.
    public var failureSummary: String? {
        attempts.last?.outcome.rawValue
    }

    /// Protocol name from the last successful DoH attempt, excluding failed or non-DoH attempts.
    public var negotiatedDoHProtocol: String? {
        attempts.last { attempt in
            attempt.outcome == .success && attempt.transport == .dnsOverHTTPS
        }?.negotiatedDoHProtocol
    }

    /// Whether any non-Device-DNS endpoint was actually attempted instead of merely suppressed by backoff.
    public var hasFallbackActivationEvidence: Bool {
        attempts.contains { attempt in
            attempt.transport != .deviceDNS && attempt.outcome != .backedOff
        }
    }

    /// Returns a copy carrying the T1 SELECTION's own outcome.
    ///
    /// Applied to the rung's primary result only, and only before its fallback legs merge — see
    /// ``tierOneSelectionOutcome`` for why that ordering is the whole point.
    internal func stampingTierOneSelectionOutcome(
        _ outcome: ResolverOrchestrator.TierOneRungOutcome?
    ) -> DNSResolutionResult {
        var copy = self
        copy.tierOneSelectionOutcome = outcome
        return copy
    }

    /// Returns a copy carrying one raw tier result before fallback legs merge.
    public func appendingTierEvidence(_ evidence: ResolverTierEvidence) -> DNSResolutionResult {
        var copy = self
        copy.tierEvidence.append(evidence)
        return copy
    }

    internal func withAttempts(_ newAttempts: [ResolverAttempt]) -> DNSResolutionResult {
        DNSResolutionResult(
            response: response,
            successfulResolverAddress: successfulResolverAddress,
            attempts: newAttempts,
            transport: transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: durationMilliseconds,
            // Carried, never dropped: these transformers run AFTER the rung has merged
            // (`recordingDuration` on every resolution), so rebuilding without it would
            // silently erase the rung's outcome on its way to the provider's counters.
            tierOneRung: tierOneRung,
            // Carried for the same reason, and it is the SELECTION's verdict rather than the
            // ladder's — see ``tierOneSelectionOutcome``.
            tierOneSelectionOutcome: tierOneSelectionOutcome,
            tierEvidence: tierEvidence
        )
    }

    /// Combine a primary result with an *encrypted* fallback (Device-DNS primary →
    /// Quad9 DoH). Unlike withDeviceDNSFallback this does NOT set the
    /// deviceDNSFallback flags — the encrypted fallback is a per-query safety net,
    /// not the device-DNS-fallback *mode* — so on success the result just looks
    /// like a normal resolution on the fallback's (DoH) transport.
    internal func withEncryptedFallback(_ fallbackResult: DNSResolutionResult) -> DNSResolutionResult {
        DNSResolutionResult(
            response: fallbackResult.response,
            successfulResolverAddress: fallbackResult.response == nil
                ? successfulResolverAddress
                : fallbackResult.successfulResolverAddress,
            attempts: attempts + fallbackResult.attempts,
            transport: fallbackResult.response == nil ? transport : fallbackResult.transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            usedEncryptedFallback: usedEncryptedFallback || fallbackResult.response != nil,
            durationMilliseconds: durationMilliseconds,
            // Carried, never dropped: these transformers run AFTER the rung has merged
            // (`recordingDuration` on every resolution), so rebuilding without it would
            // silently erase the rung's outcome on its way to the provider's counters.
            tierOneRung: tierOneRung,
            // Carried for the same reason, and it is the SELECTION's verdict rather than the
            // ladder's — see ``tierOneSelectionOutcome``.
            tierOneSelectionOutcome: tierOneSelectionOutcome,
            tierEvidence: tierEvidence + fallbackResult.tierEvidence
        )
    }

    internal func withDeviceDNSFallback(_ fallbackResult: DNSResolutionResult) -> DNSResolutionResult {
        DNSResolutionResult(
            response: fallbackResult.response,
            successfulResolverAddress: fallbackResult.successfulResolverAddress,
            attempts: attempts + fallbackResult.attempts,
            transport: fallbackResult.response == nil ? transport : .deviceDNS,
            udpTruncated: udpTruncated || fallbackResult.udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted || fallbackResult.tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded || fallbackResult.tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: true,
            deviceDNSFallbackSucceeded: fallbackResult.response != nil,
            deviceDNSUnavailable: fallbackResult.deviceDNSUnavailable,
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: durationMilliseconds,
            // Carried, never dropped: these transformers run AFTER the rung has merged
            // (`recordingDuration` on every resolution), so rebuilding without it would
            // silently erase the rung's outcome on its way to the provider's counters.
            tierOneRung: tierOneRung,
            // Carried for the same reason, and it is the SELECTION's verdict rather than the
            // ladder's — see ``tierOneSelectionOutcome``.
            tierOneSelectionOutcome: tierOneSelectionOutcome,
            tierEvidence: tierEvidence + fallbackResult.tierEvidence
        )
    }

    /// Returns a copy carrying the marker that says this resolution was ABANDONED, not
    /// concluded.
    ///
    /// The endpoint ladder appends the refusal itself, so this exists for the synchronous
    /// routes — plain and Device DNS — which return their own result and would otherwise
    /// arrive carrying only real failures. Without the marker the health reducer sees a
    /// terminal failure and scores `.totalFailure`, advancing aggregate outage and recovery
    /// state for a session that had already ended. Idempotent: a result already marked is
    /// returned unchanged, so a route that acquires a second gate later cannot double-append.
    internal func markingLifecycleEnded() -> DNSResolutionResult {
        guard attempts.last?.outcome.endsTheResolutionLadder != true else { return self }
        return DNSResolutionResult(
            response: response,
            successfulResolverAddress: successfulResolverAddress,
            attempts: attempts + [
                ResolverAttempt(
                    address: attempts.last?.address ?? transport.rawValue,
                    outcome: .refusedAfterLifecycleEnded,
                    transport: transport)
            ],
            transport: transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: durationMilliseconds,
            // Carried, never dropped: these transformers run AFTER the rung has merged
            // (`recordingDuration` on every resolution), so rebuilding without it would
            // silently erase the rung's outcome on its way to the provider's counters.
            tierOneRung: tierOneRung,
            // Carried for the same reason, and it is the SELECTION's verdict rather than the
            // ladder's — see ``tierOneSelectionOutcome``.
            tierOneSelectionOutcome: tierOneSelectionOutcome,
            tierEvidence: tierEvidence
        )
    }

    /// Returns a copy whose nonnegative elapsed duration is rounded to whole milliseconds.
    public func recordingDuration(since startedAt: Date, now: Date = Date()) -> DNSResolutionResult {
        let elapsedMilliseconds = max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded()))
        return DNSResolutionResult(
            response: response,
            successfulResolverAddress: successfulResolverAddress,
            attempts: attempts,
            transport: transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: elapsedMilliseconds,
            // The one transformer that runs on EVERY resolution, and therefore the one where
            // dropping either of these would erase the rung's outcome universally rather than on
            // some path.
            tierOneRung: tierOneRung,
            tierOneSelectionOutcome: tierOneSelectionOutcome,
            tierEvidence: tierEvidence
        )
    }
}

/// Applies resolver routing, endpoint failover, and one permitted fallback while delegating all wire I/O.
public struct ResolverOrchestrator: Sendable {
    /// Sendable wire-execution boundary supplied by the packet tunnel for each supported resolver transport.
    public struct Executors: Sendable {
        internal var isEndpointBackedOff: @Sendable (String) -> Bool
        internal var claimEncryptedRecovery: @Sendable ([String]) -> String?
        internal var resolveDoH: @Sendable (Data, DNSOverHTTPSEndpoint, UInt64?, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        internal var resolveDoT: @Sendable (Data, DNSOverTLSEndpoint, Bool, UInt64?, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        internal var resolveDoQ: @Sendable (Data, DNSOverQUICEndpoint, Bool, UInt64?, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        // The synchronous plain/device executors take the resolution's ADMITTED epoch
        // (trailing `UInt64`) and are expected to validate it before each wire attempt —
        // their ladders spend real UDP/TCP timeouts, which is exactly how a stale
        // resolution gets late enough to egress into the next session (Codex P1, PR #524).
        // The tunnelled executor carries no epoch: its route's own lifecycle/latch tokens
        // are validated at the same socket seam (S6, PR #518).
        // The trailing `UInt64?` is the rung's DATA PATH token, nil for every `.planned`
        // resolution. It is separate from the admitted lifecycle epoch beside it because a relatch
        // does not move that one: the tunnel session survives, only the latched resolver and
        // fallback policy change. Validated at the same socket seam as the epoch, so a
        // multi-address plan cannot spend its walk under a policy the user already replaced
        // (Codex P2, PR #608 → PR #610).
        internal var resolvePlain: @Sendable (Data, [String], DNSResolverTransport, UInt64, UInt64?, EgressInterface) -> DNSResolutionResult
        internal var resolveTunnelledPlain: @Sendable (Data, TunnelledPlainDNSRoute) -> DNSResolutionResult
        // The device executor takes the egress interface for the same reason the plain one does:
        // the T1 rung's datagram must leave on the PHYSICAL interface, and the socket layer
        // pins to the tunnel whenever chained is latched unless told otherwise. A device resolver
        // is a LAN address — sending it through the peer is a guaranteed timeout.
        internal var resolveDevice: @Sendable (Data, [String], UInt64, UInt64?, EgressInterface, DNSResolverTier) -> DNSResolutionResult
        internal var observeTierReply: @Sendable (ResolverTierEvidence) -> ResolverTierEvidence

        /// Captures the backoff gate and transport executors without transferring ownership of their underlying clients.
        /// - Parameter observeTierReply: Observes and stamps a raw Device reply before fallback merging.
        public init(
            isEndpointBackedOff: @escaping @Sendable (String) -> Bool,
            claimEncryptedRecovery: @escaping @Sendable ([String]) -> String? = { _ in nil },
            resolveDoH: @escaping @Sendable (Data, DNSOverHTTPSEndpoint, UInt64?, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
            resolveDoT: @escaping @Sendable (Data, DNSOverTLSEndpoint, Bool, UInt64?, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
            resolveDoQ: @escaping @Sendable (Data, DNSOverQUICEndpoint, Bool, UInt64?, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
            resolvePlain: @escaping @Sendable (Data, [String], DNSResolverTransport, UInt64, UInt64?, EgressInterface) -> DNSResolutionResult,
            resolveTunnelledPlain: @escaping @Sendable (Data, TunnelledPlainDNSRoute) -> DNSResolutionResult,
            resolveDevice: @escaping @Sendable (Data, [String], UInt64, UInt64?, EgressInterface, DNSResolverTier) -> DNSResolutionResult,
            observeTierReply: @escaping @Sendable (ResolverTierEvidence) -> ResolverTierEvidence = { $0 }
        ) {
            self.isEndpointBackedOff = isEndpointBackedOff
            self.claimEncryptedRecovery = claimEncryptedRecovery
            self.resolveDoH = resolveDoH
            self.resolveDoT = resolveDoT
            self.resolveDoQ = resolveDoQ
            self.resolvePlain = resolvePlain
            self.resolveTunnelledPlain = resolveTunnelledPlain
            self.resolveDevice = resolveDevice
            self.observeTierReply = observeTierReply
        }
    }

    /// Where `.plainDNS` resolves while the chained tunnel carries it (S6).
    ///
    /// The same pattern as ``EgressAllowance`` for the same module-boundary reason: the
    /// decision that plain DNS is carried through the chained session belongs to
    /// `ChainedResolverEgressPolicy` (its `.throughTunnelToUpstreamResolver` verdict), which
    /// lives in `LavaSecChainedUpstream` and which this module cannot import — so the
    /// provider makes the decision and passes the OUTCOME here as a plain value, consulted
    /// per resolution from the latched mode.
    ///
    /// Non-nil means: route `.plainDNS` into the tunnelled executor, addressed to these
    /// resolvers — the upstream's own, selected by readiness — never the plan's endpoints:
    /// a user's configured plain resolver can be a private-network address the upstream
    /// cannot reach, and disclosing the user's own resolver choice inside the tunnel is not
    /// part of what they consented to. The consult happens BEFORE the allowance, which
    /// keeps answering the one question it has always answered — may resolution leave on
    /// the PHYSICAL interface — and that answer stays no while chained.
    public struct TunnelledPlainDNSRoute: Sendable, Equatable {
        /// The selected resolver addresses, in failover order.
        public let resolverAddresses: [String]

        /// Opaque tokens naming the tunnel lifecycle AND the latch install this route
        /// was derived under.
        ///
        /// OPAQUE TO THIS MODULE, deliberately — the orchestrator never interprets
        /// them. They exist because the route is derived, the executor selected, and
        /// the wire work performed at three different instants, and the provider's
        /// state can move between any two of them: a route derived under a chained
        /// latch whose query then egresses under a DNS-only one is the leak S6 exists
        /// to close. TWO tokens because the provider's lifecycle counter and its latch
        /// are written at different moments, so neither alone names "the state this
        /// route belongs to": the counter moves before the latch is replaced, and the
        /// latch can be rewritten within one counter value. The provider derives the
        /// addresses and both tokens in ONE critical section and validates the triple —
        /// again atomically — at every attempt's egress decision (Codex, PR #518,
        /// three rounds: the per-attempt re-read, the route-vs-lifecycle split read,
        /// then the counter-vs-latch split identity).
        public let originatingLifecycle: UInt64
        /// See ``originatingLifecycle``.
        public let originatingLatchEpoch: UInt64

        /// `nil` for an empty list: a config with no usable resolver never latches
        /// (readiness), so a route with nothing to offer is unrepresentable here rather
        /// than a case every consumer must handle.
        public init?(
            resolverAddresses: [String],
            originatingLifecycle: UInt64,
            originatingLatchEpoch: UInt64
        ) {
            guard !resolverAddresses.isEmpty else { return nil }
            self.resolverAddresses = resolverAddresses
            self.originatingLifecycle = originatingLifecycle
            self.originatingLatchEpoch = originatingLatchEpoch
        }
    }

    /// Whether this orchestrator may resolve around the tunnel.
    ///
    /// Required at construction, with no default, and that is the whole design. Chained mode
    /// claims `0.0.0.0/0`, so every rung of the device-DNS ladder becomes egress on the
    /// physical interface — "fall back" and "leak" are the same action, and the ladder runs
    /// precisely when the tunnelled resolver is struggling.
    ///
    /// The decision itself belongs to `ChainedResolverEgressPolicy`, which lives in
    /// `LavaSecChainedUpstream` and which this module cannot import (the packet tunnel is that
    /// module's one approved consumer — `docs/architecture/module-boundaries.md`). So the
    /// provider makes the decision and passes the OUTCOME here as a plain value.
    ///
    /// A required parameter rather than a source pin asserting the provider mentions the
    /// policy. A pin proves a name appears; it cannot prove the value governs anything, which
    /// makes the flip to chained mode look guarded while forwarding, startup probes and
    /// recovery probes carry on leaking. This cannot be constructed without an answer.
    public struct EgressAllowance: Sendable, Equatable {
        /// Whether the device-DNS rung of the fallback ladder may run.
        public let permitsDeviceDNS: Bool
        /// Whether DoH/DoT/DoQ may run.
        ///
        /// A second dimension because device DNS is not the only physical-interface egress.
        /// The encrypted transports open their own TCP/QUIC connections on the ordinary
        /// interface, so while chained a configured DoH primary — or the encrypted rung of the
        /// fallback ladder — leaks exactly as device DNS does, just less obviously. Suppressing
        /// only device DNS left the leak open for every user whose resolver is encrypted, which
        /// is most of them.
        ///
        /// Refused rather than tunnelled AS THEMSELVES: they are TCP or QUIC, and carrying those
        /// through a userspace WireGuard session needs a TCP implementation this feature is not
        /// growing. Only plain UDP DNS is carried — see ``permitsPlainDNS`` for why "carried" is a
        /// different fact from "permitted".
        ///
        /// This field no longer decides whether an encrypted PRIMARY resolves at all. While
        /// chained, the tunnelled T0 consult runs ahead of this refusal for every transport,
        /// so an encrypted preset's queries are answered by the upstream's own `DNS =` over the
        /// session, and the user's encrypted resolver is reached as the T1 rung — on the
        /// physical interface, in a split tunnel, under
        /// ``tierOneFallbackAllowance``. Before that hoist a chained user whose preset was
        /// encrypted was refused here and never reached the tunnel: every query answered SERVFAIL
        /// with the upstream's resolver sitting there, willing and unasked.
        /// pinned: ResolverOrchestratorTests.testWhileChainedEveryTransportRidesTierZeroIncludingADegradedEncryptedPlan
        public let permitsEncryptedTransports: Bool

        /// Whether plain UDP DNS may run ON THE PHYSICAL INTERFACE.
        ///
        /// A third dimension because two booleans could not cover five transports, and
        /// `.plainDNS` was the one they did not cover. It is neither device DNS nor encrypted,
        /// so it fell between the two guards and resolved unconditionally — in the type whose
        /// stated purpose is making egress around the tunnel unrepresentable, on the transport
        /// that is the DEFAULT (`DNSResolverTransport = .plainDNS` on the orchestrator's own
        /// initialiser, and the `effectiveTransport` fallback in `DNSResolverRuntimePlan`).
        /// Since the S6 wiring the carry decides what a chained session's DNS does; this
        /// refusal decides only what may leave on the physical interface, and it is the
        /// BACKSTOP the carry stands in front of.
        ///
        /// FALSE while chained even though plain UDP DNS is the one transport the design
        /// carries THROUGH the tunnel (S6). The carry does not consult this field: the
        /// orchestrator routes `.plainDNS` into the tunnelled executor — whenever the
        /// provider supplies a ``TunnelledPlainDNSRoute`` — BEFORE this allowance is
        /// consulted, exactly so this field keeps answering the one question it has always
        /// answered: may resolution leave on the PHYSICAL interface. That answer stays no
        /// while chained. With no route supplied — DNS-only mode, or a latched chained
        /// session whose route derivation ever disagreed with the readiness gate that
        /// admitted it — `.plainDNS` answers fail-closed per `INV-DNS-1` rather than
        /// leaking.
        /// pinned: ResolverOrchestratorTests.testChainedModeRefusesPlainDNSWhenNoRouteIsSupplied
        public let permitsPlainDNS: Bool

        /// Whether the T1 rung may leave on the physical interface: the user's chosen
        /// resolver, reached only for a name the chained T0 (the conf's own `DNS =`) did
        /// not serve.
        ///
        /// A FOURTH dimension rather than a relaxation of the three above, and the split is
        /// load-bearing. Those three answer "may the ordinary ladder leave on the physical
        /// interface", and while chained the answer stays NO for all of them — the T0
        /// path is byte-for-byte what it was. This answers a narrower question about a rung
        /// that only exists after T0 has already failed to serve, so relaxing
        /// ``permitsEncryptedTransports`` instead would also have let a configured DoH PRIMARY
        /// egress around the tunnel, which is the leak the type exists to prevent.
        ///
        /// The decision belongs to `ChainedResolverEgressPolicy`
        /// (`permitsTierOneFallbackOnPhysicalInterface`, which reads the latched routing
        /// policy); this module cannot import `LavaSecChainedUpstream`, so the provider passes
        /// the outcome as a plain value exactly as it does for the other three.
        /// pinned: ResolverOrchestratorTests.testTheChainedAllowancesDifferOnlyInTheTierOneDimension
        public let permitsTierOneFallbackOnPhysicalInterface: Bool

        public init(
            permitsDeviceDNS: Bool,
            permitsEncryptedTransports: Bool,
            permitsPlainDNS: Bool,
            permitsTierOneFallbackOnPhysicalInterface: Bool
        ) {
            self.permitsDeviceDNS = permitsDeviceDNS
            self.permitsEncryptedTransports = permitsEncryptedTransports
            self.permitsPlainDNS = permitsPlainDNS
            self.permitsTierOneFallbackOnPhysicalInterface =
                permitsTierOneFallbackOnPhysicalInterface
        }

        /// The allowance the T1 rung itself runs under, or `nil` when this allowance has no
        /// physical-path T1.
        ///
        /// Derived rather than passed, so the rung's permissions cannot drift from the
        /// permission to have a rung at all. Three properties, each deliberate:
        ///
        /// - **Device DNS is TRUE when the user chose it, and only then.** The distinction is
        ///   between a resolver IMPOSED on the rung and one SELECTED for it. A device-wide
        ///   fallback EPISODE must never rewrite the rung into a device-DNS plan behind the
        ///   user's back — `ignoresDeviceDNSFallbackMode: true` at the plan site is what stops
        ///   that, and it still does. But a user whose one resolver selection IS Device DNS has
        ///   asked for the network's own resolver, and refusing it there protected nothing they
        ///   had: Lava already sends every DNS-only query to it, and Lava's blocklist runs
        ///   before the upstream query either way, so filtering is not lost.
        ///
        ///   THE COMPARISON THAT SETTLED IT is the profile this feature exists for. Native
        ///   Tailscale with MagicDNS and no global nameservers serves tailnet names and lets
        ///   everything else fall through to the system's own DHCP resolvers. A user chaining
        ///   through an exported WireGuard conf is asking for that same shape; refusing the
        ///   fall-through half gave them something strictly worse than running Tailscale
        ///   directly, for a threat (`LAV-87`) they had already declined to be protected from
        ///   by choosing Device DNS at all (founder, 2026-08-27).
        /// - **Plain DNS is TRUE.** A user whose single resolver selection is a plain-IP preset
        ///   gets that resolver, unencrypted, on the physical path. Split tunnel already
        ///   discloses the destination and SNI to the same observer, and silently substituting
        ///   a different transport would override an explicit choice (resolved decision D1,
        ///   plan `2026-08-26-unified-resolver-picker-and-split-tunnel-tier-two-egress`).
        ///   The UI discloses it.
        /// - **No recursion.** The derived allowance's own T1 flag is false, so a rung
        ///   cannot spawn a rung.
        /// pinned: ResolverOrchestratorTests.testTheTierOneRungPermitsEveryTransportAndNeverSpawnsARung
        /// pinned: ResolverOrchestratorTests.testTheChainedPrimaryAllowancesStillRefuseDeviceDNS
        public var tierOneFallbackAllowance: EgressAllowance? {
            guard permitsTierOneFallbackOnPhysicalInterface else { return nil }
            return EgressAllowance(
                permitsDeviceDNS: true,
                permitsEncryptedTransports: true,
                permitsPlainDNS: true,
                permitsTierOneFallbackOnPhysicalInterface: false)
        }

        /// Whether `transport` may leave via the physical interface under this allowance.
        ///
        /// EXHAUSTIVE, and that is the point of it existing. The two-boolean shape let a
        /// transport be added — or simply overlooked — without anyone being asked what should
        /// happen to it, and the silent answer was "permitted". This `switch` has no `default`,
        /// so a sixth `DNSResolverTransport` case does not compile until someone decides. The
        /// leak is unrepresentable when forgetting is a build error rather than a permit.
        public func permits(_ transport: DNSResolverTransport) -> Bool {
            switch transport {
            case .deviceDNS:
                return permitsDeviceDNS
            case .plainDNS:
                return permitsPlainDNS
            case .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC:
                return permitsEncryptedTransports
            }
        }

        /// DNS-only mode: nothing is suspended, which is today's shipping behaviour.
        ///
        /// Named rather than defaulted. A default would let a caller acquire it by silence,
        /// and "no one thought about it" would produce the permissive answer — which is the
        /// leak. Passing this is a statement that the tunnel is not chained.
        public static let dnsOnlyMode = EgressAllowance(
            permitsDeviceDNS: true, permitsEncryptedTransports: true, permitsPlainDNS: true,
            // No T1 rung outside chained mode: here the user's chosen resolver IS the
            // primary, reached by the ordinary ladder above.
            permitsTierOneFallbackOnPhysicalInterface: false)

        /// Chained FULL tunnel: the ladder is suspended because every rung egresses around the
        /// tunnel, and there the tunnel really is carrying everything — DNS would be the only
        /// thing the local network could still see.
        public static let chainedMode = EgressAllowance(
            permitsDeviceDNS: false, permitsEncryptedTransports: false, permitsPlainDNS: false,
            permitsTierOneFallbackOnPhysicalInterface: false)

        /// Chained SPLIT tunnel: the T0 ladder is suspended exactly as in ``chainedMode``,
        /// and the T1 rung may leave on the physical interface.
        ///
        /// The three suspended dimensions are IDENTICAL to `chainedMode` on purpose: a split
        /// tunnel changes nothing about where the primary resolves. What it changes is that
        /// general traffic already goes direct, so a name sent to the user's chosen resolver
        /// reaches an observer who is already watching that connection — see
        /// `ChainedResolverEgressPolicy.permitsTierOneFallbackOnPhysicalInterface` for the
        /// field evidence and the full argument.
        ///
        /// Named and explicit like its two siblings. A caller acquires it by deciding, never by
        /// silence.
        public static let chainedSplitTunnelMode = EgressAllowance(
            permitsDeviceDNS: false, permitsEncryptedTransports: false, permitsPlainDNS: false,
            permitsTierOneFallbackOnPhysicalInterface: true)
    }

    /// Plain UDP DNS, or the refusal that stands in for it.
    ///
    /// THE ONLY PATH to `executors.resolvePlain`, and that is the point. Guarding the
    /// `.plainDNS` branch alone left three others open: an encrypted plan with no endpoints of
    /// its own DEGRADES to plain DNS, and those branches called the executor directly. The
    /// transport check above them tests `plan.transport` — what was PLANNED — so a DoH plan was
    /// admitted on the encrypted allowance and then egressed as plain DNS, which the allowance
    /// may separately forbid. The guard and the egress were about different transports.
    ///
    /// Reachable now on the T1 RUNG, whose derived allowance permits both plain and the
    /// encrypted transports — a degraded encrypted plan on that rung resolves as plain, on the
    /// physical interface, which is the resolver the user picked answering a name T0 did not
    /// serve. Under the two PLANNED-rung allowances it stays unreachable as before: `dnsOnlyMode`
    /// permits everything and `chainedMode` permits nothing.
    ///
    /// NO LONGER THE CHAINED DECISION POINT. The S6 rule was that an encrypted plan degrading
    /// here while chained is REFUSED rather than carried, because answering via the upstream's
    /// plain resolver would silently change the operator the user chose. That reasoning held
    /// while their selection WAS the chained primary. It is not: the tunnelled T0 consult
    /// now runs ahead of the transport switch for every transport, so a chained resolution
    /// reaches this function only when there is no tunnelled route at all, or when it IS the
    /// T1 rung — where the user's own selection is exactly what is being resolved, on the
    /// physical interface, under the derived allowance.
    ///
    /// Answered rather than dropped, per `INV-DNS-1`, with the attempt recorded so a refusal is
    /// not rendered as success by `failureSummary ?? "success"`.
    private func resolvePlainWithinAllowance(
        _ query: Data,
        plan: DNSResolverRuntimePlan,
        admittedAtEpoch: UInt64,
        rung: ResolutionRung = .planned,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        guard rung.allowance(egressAllowance).permits(.plainDNS) else {
            completion(
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [
                        ResolverAttempt(
                            address: Self.refusedEndpointIdentity(for: plan),
                            outcome: .refusedByEgressPolicy,
                            transport: .plainDNS)
                    ],
                    transport: .plainDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false))
            return
        }
        // THE RUNG'S DATAGRAM MUST LEAVE THE TUNNEL, and only this parameter makes it. The
        // allowance above has already said the T1 rung MAY egress physically; the socket layer
        // decides WHICH interface, and left to itself it pins to the tunnel whenever chained is
        // latched (Codex, PR #590).
        // pinned: ResolverOrchestratorTests.testTheRungAsksForThePhysicalInterface
        completion(
            executors.resolvePlain(
                query, plan.plainAddresses, .plainDNS, admittedAtEpoch,
                rung.admittedAtLatchEpoch, rung.egressInterface))
    }

    /// Names the endpoint an egress refusal declined, for the attempt record.
    ///
    /// Diagnostics need to say WHICH resolver was refused, not merely that one was — a field
    /// report reading "refused-by-egress-policy" with no identity cannot distinguish a user's
    /// configured DoH endpoint from the fallback.
    private static func refusedEndpointIdentity(for plan: DNSResolverRuntimePlan) -> String {
        switch plan.transport {
        case .dnsOverHTTPS:
            return plan.dohEndpoints.first?.url.host ?? "doh"
        case .dnsOverTLS:
            return plan.dotEndpoints.first?.hostname ?? "dot"
        case .dnsOverQUIC:
            return plan.doqEndpoints.first?.hostname ?? "doq"
        case .plainDNS, .deviceDNS:
            return plan.plainAddresses.first ?? "plain"
        }
    }

    private let executors: Executors
    /// Read per resolution, not captured once.
    ///
    /// A stored value made the orchestrator itself session-scoped, which meant rebuilding it
    /// on every `startTunnel` — a WRITE to a property that per-query work reads from a
    /// concurrent queue, racing any resolution still in flight from the previous session. The
    /// design before this slice had exactly one initialisation and no writes, and that was
    /// load-bearing.
    ///
    /// A closure restores that: the orchestrator is built once and the allowance is answered
    /// from the latched mode each time it is needed, so it is always current without anything
    /// being mutated.
    private let egressAllowance: @Sendable () -> EgressAllowance
    /// Read per resolution, like the allowance and for the same reasons: built once, never
    /// written, always answering from the latched mode.
    private let tunnelledPlainDNSRoute: @Sendable () -> TunnelledPlainDNSRoute?
    /// The plan the T1 RUNG resolves against, or `nil` when this session has no rung.
    ///
    /// A SEPARATE CLOSURE, AND THAT IS THE WHOLE POINT. The rung used to re-resolve the caller's
    /// own `plan`, so the decision "is there a rung at all, and against what" was made here, from
    /// a value built for T0. The provider owns that decision: it knows the latched selection,
    /// the routing policy and whether the selection can be a rung at all. Reading the caller's
    /// plan meant a physical-interface lookup happened whether or not one was warranted, which is
    /// an egress nobody asked for (Codex, PR #590).
    ///
    /// `nil` IS THE CLOSED DIRECTION and is load-bearing: no plan means no rung, so T0's
    /// answer stands exactly as it does under `chainedMode`. Read per resolution, like the
    /// allowance and the route, so nothing here is written after construction.
    private let tierOneFallbackPlan: @Sendable () -> DNSResolverRuntimePlan?
    /// Names the caller's CURRENT session, so an in-flight resolution can be told from one
    /// whose session has ended. Read per resolution and again before every wire attempt, like
    /// the two closures above and for the same build-once reason.
    ///
    /// WHY A RESOLUTION NEEDS AN IDENTITY AT ALL. Teardown does not drain in-flight resolver
    /// work; it cancels transports and asks them to refuse. That closes the window between a
    /// stop and the next start, but not the case where the next start has already happened:
    /// transport cancellation is asynchronous, so a lane's cancellation can run AFTER the new
    /// session re-armed everything, report its failure, and send `resolveEndpoints` on to the
    /// next endpoint — which is then admitted, because by every state the transport can see it
    /// is the new session asking. The old lifecycle became indistinguishable from the new one
    /// (Codex P1, PRs #522/#523).
    ///
    /// An epoch makes them distinguishable at the only place that can tell: the resolution
    /// itself, which knows when it began. Snapshot at entry, compare before each attempt, and
    /// work whose session ended is refused however late it arrives — the same shape as
    /// ``TunnelledPlainDNSRoute/originatingLifecycle`` and the provider's own evidence seams.
    ///
    /// ZERO MEANS NO SESSION and admits nothing, including a snapshot of zero. That is what
    /// makes "the provider is gone" and "the tunnel is stopped" refuse rather than match
    /// themselves — an equality test alone would admit both.
    private let admissionEpoch: @Sendable () -> UInt64
    private let currentPathEpoch: @Sendable () -> Int?

    /// Creates an orchestrator backed by caller-owned transport executors and endpoint backoff state.
    ///
    /// - Parameter egressAllowance: answers whether resolution may leave via the physical
    ///   interface, consulted per resolution. No default: see ``EgressAllowance``.
    /// - Parameter tunnelledPlainDNSRoute: answers whether — and to which resolvers —
    ///   `.plainDNS` is carried through the chained session, consulted per resolution.
    ///   No default, deliberately: a defaulted `{ nil }` would let the provider compile
    ///   without ever deciding, which is the guarded-looking-but-leaking shape the
    ///   required `egressAllowance` exists to prevent. See ``TunnelledPlainDNSRoute``.
    /// - Parameter admissionEpoch: names the caller's current session. No default for the
    ///   third time and the sharpest reason: a defaulted constant would admit every stale
    ///   resolution while every test and call site still compiled and passed. See
    ///   ``admissionEpoch``.
    /// - Parameter currentPathEpoch: captures the provider's path identity at each leg launch;
    ///   Device DNS additionally requires send-time epochs from its executor's attempts.
    /// - Parameter tierOneFallbackPlan: the resolver the T1 rung asks, or `nil` for no rung.
    ///   No default for the fourth time, and here the reason inverts: `{ nil }` would be the
    ///   SAFE answer, not the leaking one, so a default would be silently accepted forever by a
    ///   caller that meant to supply a plan — the feature would simply never fire, and nothing
    ///   would fail. Making it explicit is what turns "no T1" into a decision. See
    ///   ``tierOneFallbackPlan``.
    public init(
        executors: Executors,
        egressAllowance: @escaping @Sendable () -> EgressAllowance,
        tunnelledPlainDNSRoute: @escaping @Sendable () -> TunnelledPlainDNSRoute?,
        admissionEpoch: @escaping @Sendable () -> UInt64,
        currentPathEpoch: @escaping @Sendable () -> Int? = { nil },
        tierOneFallbackPlan: @escaping @Sendable () -> DNSResolverRuntimePlan?
    ) {
        self.executors = executors
        self.egressAllowance = egressAllowance
        self.tunnelledPlainDNSRoute = tunnelledPlainDNSRoute
        self.admissionEpoch = admissionEpoch
        self.currentPathEpoch = currentPathEpoch
        self.tierOneFallbackPlan = tierOneFallbackPlan
    }

    /// Binds the existing tier and egress rules to one lookup's lifetime and transport seams.
    /// The bound instance is retained by its callbacks until underlying work actually finishes.
    public func scoped(to lifetime: DNSResolutionLifetime, executors: Executors) -> ResolverOrchestrator {
        ResolverOrchestrator(
            executors: executors, egressAllowance: egressAllowance,
            tunnelledPlainDNSRoute: tunnelledPlainDNSRoute,
            admissionEpoch: { lifetime.isAdmitted ? self.admissionEpoch() : 0 },
            currentPathEpoch: currentPathEpoch,
            tierOneFallbackPlan: tierOneFallbackPlan)
    }

    /// Whether work admitted under `snapshot` may still run against the `live` epoch.
    ///
    /// Both halves are load-bearing: a snapshot must match the live epoch, AND neither may be
    /// zero. Equality alone would admit a resolution that began with no session against a
    /// caller that still has none.
    ///
    /// The ONE spelling of that rule, `static` and `public` so every checkpoint — the
    /// orchestrator's gates here, and the provider's egress-adjacent rechecks (the smoke
    /// probe's queued device fallback, the socket-seam guards) — consults the same predicate
    /// instead of growing a second one that can drift.
    public static func workIsAdmitted(snapshot: UInt64, live: UInt64) -> Bool {
        snapshot != 0 && snapshot == live
    }

    /// ``workIsAdmitted(snapshot:live:)`` against this orchestrator's live epoch.
    private func admissionIsCurrent(_ epoch: UInt64) -> Bool {
        Self.workIsAdmitted(snapshot: epoch, live: admissionEpoch())
    }

    /// Whether the DATA PATH a T1 rung was admitted under is still the installed one.
    ///
    /// A SECOND QUESTION FROM ``admissionIsCurrent``, not a stricter version of it. That asks
    /// whether the tunnel SESSION is still live, and it is answered by `admissionEpoch`, which is
    /// the provider's lifecycle generation. A relatch does not move the lifecycle — it replaces
    /// the latched configuration inside one — so every one of those guards passes straight through
    /// a resolver change that has already taken effect everywhere else.
    ///
    /// That gap only leaks for the T1 rung. T0's route seals its own latch epoch and the
    /// executor validates it at every attempt; the rung carries a bare plan, so a plan obtained
    /// before a relatch could still put a datagram on the wire after it — to the device resolver
    /// the user had just turned OFF, which is `INV-DNS-1`'s direction reversed (Codex P2, PR #608).
    ///
    /// READ THROUGH THE ROUTE, because the provider derives it and the latch epoch together in one
    /// critical section, so the pair cannot be observed half-updated. A `nil` route means chained
    /// mode is gone entirely, which is the closed answer here: `false`.
    ///
    /// `.planned` always passes — it has no latch token, and nothing about it is unfenced.
    /// pinned: ResolverOrchestratorTests.testARelatchStopsTheRungsDeviceLegFromEgressing
    private func rungLatchIsCurrent(_ rung: ResolutionRung) -> Bool {
        guard let admittedAt = rung.admittedAtLatchEpoch else { return true }
        guard let route = tunnelledPlainDNSRoute() else { return false }
        return route.originatingLatchEpoch == admittedAt
    }

    /// The result a resolution gets when its session ended underneath it.
    ///
    /// An attempt record rather than an empty array, for the reason `.refusedByEgressPolicy`
    /// carries one: `failureSummary` reads `attempts.last?.outcome`, and the smoke-probe log
    /// renders `failureSummary ?? "success"` — so a refusal with no attempts is logged as a
    /// successful resolution.
    private func staleLifecycleResult(
        for plan: DNSResolverRuntimePlan, previousAttempts: [ResolverAttempt] = []
    ) -> DNSResolutionResult {
        DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: previousAttempts + [
                ResolverAttempt(
                    address: Self.refusedEndpointIdentity(for: plan),
                    outcome: .refusedAfterLifecycleEnded,
                    transport: plan.transport)
            ],
            transport: plan.transport,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
    }

    // Primary resolution then a single fallback, run only when the primary
    // produced no response and the plan allows it. The fallback direction depends
    // on the primary: an encrypted primary falls back to Device DNS
    // (shouldFallbackToDeviceDNS); a Device-DNS primary falls back to an encrypted
    // resolver (shouldFallbackToEncrypted, Quad9 DoH). The two are mutually
    // exclusive.
    /// Resolves the primary route and, only when policy permits, performs a single device or encrypted fallback.
    /// - Parameter admittedAtEpoch: the session that ACCEPTED this work, when the caller
    ///   accepted it somewhere earlier than this call. Defaults to a snapshot taken here.
    ///
    ///   The distinction is not academic. The packet tunnel admits DNS work through a bounded
    ///   FIFO and retains over-bound requests as closures; a query accepted in session A can
    ///   therefore reach this method only after session B has begun, and a snapshot taken
    ///   here would name B — so every gate downstream would agree that A's work belongs to B
    ///   and admit all of it (Codex P1, PR #524). A caller that queues must capture its epoch
    ///   where it ACCEPTS the work and pass it in.
    public func resolveUpstream(
        _ query: Data,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool = false,
        admittedAtEpoch: UInt64? = nil,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        // Snapshot at the caller's entry and threaded down — never re-read as "the current
        // epoch" further in. Re-reading would make every check compare the live value with
        // itself and pass unconditionally, which is the guard that looks present and
        // enforces nothing.
        resolveUpstream(
            query,
            plan: plan,
            usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections,
            admittedAtEpoch: admittedAtEpoch ?? admissionEpoch(),
            completion: completion)
    }

    /// - Parameter rung: which rung of the chained ladder this resolution IS. `.planned` is the
    ///   ordinary entry — T1 in DNS-only, T0 while chained. `.tierOneFallback` means the chained
    ///   T1 rung is running its own full ladder, which is why this parameter exists at all:
    ///   before it, the rung was dispatched straight into `resolvePrimaryUpstream`, so it got the
    ///   primary route's endpoint failover and NONE of the cross-route fallbacks below. A chained
    ///   user's second opinion was one route deep where a DNS-only user's is three, and on a
    ///   network whose device resolvers had moved (a train, a tower handover) the rung asked a
    ///   stale address and there was nothing beneath it (founder field report, 2026-08-27;
    ///   `lavasec-infra plans/2026-08-27-chained-resolver-adaptation-and-tier-three.md`).
    ///
    ///   Every gate below reads the RUNG'S allowance and egress interface rather than the
    ///   orchestrator's, because a rung that egresses physically must have its fallbacks egress
    ///   physically too — a fallback that quietly reverted to `.providerDefault` would send the
    ///   rescue query back into the tunnel that just failed to answer.
    private func resolveUpstream(
        _ query: Data,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool,
        admittedAtEpoch: UInt64,
        rung: ResolutionRung = .planned,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        let executors = executors
        let observationPathEpoch = currentPathEpoch()
        let selectedTier: DNSResolverTier = plan.usesDeviceDNSFallbackMode
            ? .tierTwo : plan.configuredPrimaryTier
        resolvePrimaryUpstream(
            query,
            plan: plan,
            usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections,
            admittedAtEpoch: admittedAtEpoch,
            rung: rung, tier: selectedTier
        ) { rawPrimaryResult in
            // THE SELECTION'S OWN VERDICT, STAMPED HERE AND NOWHERE LATER. Below this line the
            // rung's device-DNS and encrypted legs merge their attempts and their response into
            // this result, and once they have, no reader can tell the selection's replies from
            // theirs — `attempts` is a plain concatenation with no boundary marker. Deriving the
            // chained fallback counters after the merge credited a fallback's rescue to the
            // selection that had just failed (PR #606); this is the one point where the question
            // is still answerable.
            //
            // A no-op for `.planned`, which is every DNS-only resolution: the stamp is nil and
            // the ladder below is byte-for-byte unchanged.
            // The compatibility counters still describe saved T1. A solely active saved
            // T2 can serve the physical ladder without crediting the disabled T1 selection.
            // pinned: ResolverOrchestratorTests.testSoleEnabledSavedTierTwoKeepsItsNumberInDNSOnlyAndChainedSplitExecution
            let selectedResult = selectedTier == .tierOne
                ? Self.stampingTierOneSelectionOutcome(rawPrimaryResult, rung: rung)
                : rawPrimaryResult
            let primaryResult = self.stampingPhysicalTierEvidenceIfNeeded(
                selectedResult, tier: selectedTier,
                plan: plan, admittedAtEpoch: admittedAtEpoch, rung: rung,
                observationPathEpoch: observationPathEpoch)
            let hasResponse = primaryResult.response != nil

            // Re-checked before the FALLBACK, not just at entry, because the primary is
            // exactly what makes this late: a device-DNS or plain primary spends real UDP
            // timeouts, and a tunnel that stops during them would otherwise have its
            // encrypted or device fallback admitted into whatever session exists by the time
            // the ladder gets here.
            guard self.admissionIsCurrent(admittedAtEpoch) else {
                // MARKED, not passed through. The endpoint ladder appends
                // `.refusedAfterLifecycleEnded` itself, but a plain- or Device-DNS primary is
                // synchronous and returns its own result — so a stale one arrived carrying
                // only real failures, and the health reducer, seeing no refusal, scored it
                // `.totalFailure` and advanced aggregate outage and recovery state for a
                // resolution whose session had ended (Codex P2, PR #524). The real attempts
                // are preserved; the marker is what selects the neutral abandoned path.
                completion(primaryResult.markingLifecycleEnded())
                return
            }

            // THE LATCH IS RE-READ BEFORE THE FALLBACK, and this is the window that actually
            // leaks. The selection has just spent its full timeout, which is seconds — ample for
            // a reload to replace the latch — and the plan below was chosen under the OLD one. A
            // device leg admitted by a `shouldFallbackToDeviceDNS` the user has since cleared is
            // the PR #575 privacy failure arriving one rung down (Codex P2, PR #608).
            //
            // REFUSED BY NOT RUNNING THE LEG, returning what the selection already produced —
            // deliberately not a new refusal outcome. The result then folds onto T0 exactly as
            // a failed device leg would, so it fails CLOSED, and the selection's own stamped
            // verdict stays honest: it did attempt, and that is what the counters record.
            guard self.rungLatchIsCurrent(rung) else {
                completion(primaryResult)
                return
            }

            if plan.shouldFallbackToDeviceDNS,
                rung.allowance(self.egressAllowance).permits(.deviceDNS) {
                // Encrypted primary → Device DNS, but ONLY when there was no response
                // at all. A resolver-declared SERVFAIL/REFUSED (e.g. a DNSSEC
                // validation or policy failure from a configured encrypted resolver)
                // is an authoritative verdict; silently retrying it on the
                // less-filtered Device DNS would change/leak the answer, so the
                // device-fallback contract stays "no response only".
                guard !hasResponse else {
                    completion(primaryResult)
                    return
                }
                // THE RUNG'S INTERFACE, not a hardcoded `.providerDefault`. For `.planned` this
                // still resolves to `.providerDefault` — the DNS-ONLY device ladder, unchanged.
                // For the T1 rung it is `.physical`, and it has to be: the rung exists
                // because the tunnelled T0 did not serve, so sending its device fallback
                // back through the provider's default mode would aim the rescue at the path
                // that just failed.
                let fallbackPathEpoch = self.currentPathEpoch()
                let rawFallbackResult = executors.resolveDevice(
                    query, plan.deviceDNSFallbackAddresses, admittedAtEpoch,
                    rung.admittedAtLatchEpoch, rung.egressInterface, .tierTwo)
                let evidence = self.observingDeviceTierReply(ResolverTierEvidence(
                    tier: .tierTwo, resolverKind: .device, egress: .physical,
                    result: rawFallbackResult,
                    originatingLifecycle: rung.originatingLifecycle ?? admittedAtEpoch,
                    originatingLatchEpoch: rung.admittedAtLatchEpoch,
                    observationPathEpoch: fallbackPathEpoch))
                let fallbackResult = rawFallbackResult.appendingTierEvidence(evidence)
                // Re-checked AFTER the synchronous fallback as well: the device ladder
                // spends real UDP timeouts, and a session that ends inside them would
                // otherwise complete this resolution with only real failures — which the
                // health reducer scores `.totalFailure`, advancing aggregate outage and
                // recovery state for a resolution that was abandoned (Codex P2, PR #524).
                // The executor's own socket-seam guard usually marks the ladder first;
                // this covers a session that ends after the last wire attempt returns.
                guard self.admissionIsCurrent(admittedAtEpoch) else {
                    completion(
                        primaryResult.withDeviceDNSFallback(fallbackResult).markingLifecycleEnded())
                    return
                }
                completion(primaryResult.withDeviceDNSFallback(fallbackResult))
            // NOT A SECOND CONSULT OF THE TUNNELLED ROUTE — which is a narrower condition than
            // "not while chained", and the narrowing is this diff.
            //
            // The gate exists because of a re-entry bug. It used to be absent entirely, on the
            // reasoning that `resolvePrimaryUpstream(fallbackPlan)` refuses DoH/DoT/DoQ under
            // `.chainedMode` before any executor runs. THE HOIST FALSIFIED THAT: the tunnelled
            // T0 consult runs at the top of `resolvePrimaryUpstream`, ahead of the transport
            // gate, so a re-entry never reaches the refusal. It consulted the tunnelled route a
            // SECOND time — ignoring `fallbackPlan` entirely, so the configured encrypted
            // fallback was never attempted — and could spawn a second T1 rung, double-counting
            // the rung's evidence (Codex, PR #590).
            //
            // `tunnelledPlainDNSRoute() == nil` was a PROXY for "this would re-enter T0", and
            // it was too coarse: it also refused the encrypted fallback to the T1 RUNG, which
            // cannot re-enter anything — `.tierOneFallback.consultsTunnelledRoute` is false, so
            // the block it would supposedly recurse into is already unreachable from it. The cost
            // of the proxy was the rung having no third rung: when the user's chosen resolver
            // failed there was nothing beneath it, while the identical DNS-only query fell through
            // to the encrypted fallback. On a train, with a device-DNS selection captured on a
            // tower the phone had since left, that is the difference between a name resolving and
            // not (founder field report, 2026-08-27).
            //
            // So gate on the RUNG, which is the fact the proxy was standing in for. For
            // `.planned` the behaviour is byte-for-byte what it was; for the rung the ladder
            // continues.
            // pinned: ResolverOrchestratorTests.testTheEncryptedFallbackDoesNotReRunTheChainedLadder
            // pinned: ResolverOrchestratorTests.testTheTierOneRungRunsTheFullFallbackLadder
            } else if plan.shouldFallbackToEncrypted, let fallbackPlan = plan.encryptedFallback?.plan,
                !rung.consultsTunnelledRoute || tunnelledPlainDNSRoute() == nil {
                // Device-DNS primary → encrypted fallback resolved through the
                // user-selected fallback resolver and its transport. The primary
                // produced no usable answer when it returned nothing, OR returned a
                // server-side failure or malformed response *while the resolver is already
                // health-confirmed as broadly wedged*. The latter is the stale
                // off-network resolver case (a reachable-but-stale Device-DNS address
                // refuses every query) — a bare `response == nil` guard would hand that
                // failing reply back. But a refusal on an otherwise-healthy resolver is
                // an authoritative per-domain verdict (a managed-network block or a
                // DNSSEC failure) and must pass through untouched, so the rejection
                // path is gated on `treatsResolverRejectionAsFallbackTrigger`.
                // Structurally valid NOERROR/NODATA and NXDOMAIN remain authoritative.
                let isWedgeRejection = plan.treatsResolverRejectionAsFallbackTrigger
                    && DNSResolverSmokeProbe.indicatesResolverFailure(primaryResult.response)
                let deviceUsable = hasResponse && !isWedgeRejection
                guard !deviceUsable else {
                    completion(primaryResult)
                    return
                }
                // Route the per-query fallback through the selected resolver's transport.
                // resolvePrimaryUpstream/resolveEndpoints already applies the backoff gate
                // for DoH/DoT/DoQ, so the old manual isEndpointBackedOff check is dropped.
                let fallbackPathEpoch = self.currentPathEpoch()
                resolvePrimaryUpstream(
                    query,
                    plan: fallbackPlan,
                    usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections,
                    admittedAtEpoch: admittedAtEpoch,
                    rung: rung, tier: .tierTwo
                ) { fallbackResult in
                    let evidence = self.observingDeviceTierReply(ResolverTierEvidence(
                        tier: .tierTwo, resolverKind: fallbackPlan.transport == .deviceDNS ? .device : .fixed,
                        egress: .physical, result: fallbackResult,
                        originatingLifecycle: rung.originatingLifecycle ?? admittedAtEpoch,
                        originatingLatchEpoch: rung.admittedAtLatchEpoch,
                        observationPathEpoch: fallbackPathEpoch))
                    completion(primaryResult.withEncryptedFallback(fallbackResult.appendingTierEvidence(evidence)))
                }
            } else {
                completion(primaryResult)
            }
        }
    }

    /// Executes only the plan's primary route, including ordered endpoint failover but no cross-route fallback.
    /// - Parameter admittedAtEpoch: see ``resolveUpstream(_:plan:usesIsolatedEncryptedConnections:admittedAtEpoch:completion:)``.
    public func resolvePrimaryUpstream(
        _ query: Data,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool = false,
        admittedAtEpoch: UInt64? = nil,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        let epoch = admittedAtEpoch ?? admissionEpoch()
        let observationPathEpoch = currentPathEpoch()
        resolvePrimaryUpstream(
            query,
            plan: plan,
            usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections,
            admittedAtEpoch: epoch,
            tier: plan.usesDeviceDNSFallbackMode ? .tierTwo : plan.configuredPrimaryTier
        ) { result in
            completion(self.stampingPhysicalTierEvidenceIfNeeded(
                result, tier: plan.usesDeviceDNSFallbackMode ? .tierTwo : plan.configuredPrimaryTier,
                plan: plan, admittedAtEpoch: epoch, rung: .planned,
                observationPathEpoch: observationPathEpoch))
        }
    }

    private func stampingPhysicalTierEvidenceIfNeeded(
        _ result: DNSResolutionResult, tier: DNSResolverTier, plan: DNSResolverRuntimePlan,
        admittedAtEpoch: UInt64, rung: ResolutionRung, observationPathEpoch: Int?
    ) -> DNSResolutionResult {
        // A chained planned result already owns its T0 and physical-rung evidence. Stamping
        // the final rescued response here would invent a second T1 and erase the boundary.
        guard result.tierEvidence.isEmpty else { return result }
        let evidence = observingDeviceTierReply(ResolverTierEvidence(
            tier: tier, resolverKind: plan.transport == .deviceDNS ? .device : .fixed,
            egress: .physical, result: result,
            originatingLifecycle: rung.originatingLifecycle ?? admittedAtEpoch,
            originatingLatchEpoch: rung.admittedAtLatchEpoch,
            observationPathEpoch: observationPathEpoch))
        return result.appendingTierEvidence(evidence)
    }

    // A Device leg can reply while its slower fallback is still running. Report that
    // liveness at sealing, before the merged completion can arrive behind another failure.
    private func observingDeviceTierReply(_ evidence: ResolverTierEvidence) -> ResolverTierEvidence {
        guard evidence.resolverKind == .device,
              evidence.outcome == .served || evidence.outcome == .answered else { return evidence }
        let observed = executors.observeTierReply(evidence)
        // A truncated UDP reply was already fenced before the TCP retry. Sealing the
        // entire leg must retain that order instead of turning it into a newer reply.
        if let originalReplySequence = evidence.replySequence {
            return observed.recordingReply(observationSequence: originalReplySequence)
        }
        return observed
    }

    /// Whether T0's result is the UPSTREAM declining to serve — the only thing that may open
    /// the physical rung.
    ///
    /// STRICTLY NARROWER THAN ``declinedToServe``, and the difference is the whole point. That
    /// predicate asks "is this an answer the client can be given", which is the right question at
    /// the MERGE. Here the question is different: "did the upstream's own resolver fail to serve
    /// this name" — and a result with no reply is only evidence about the upstream if a datagram
    /// actually left the device.
    ///
    /// TWO REAL T0 SHAPES NEVER REACH THE WIRE, and both are ordinary rather than exotic:
    /// `.backedOff` (the provider returns every address backed off WITHOUT running the tunnelled
    /// loop at all) and `.socketUnavailable` / `.tunnelInterfaceUnavailable` /
    /// `.physicalInterfaceUnavailable` (no interface to send on yet — the first fires for seconds
    /// at every chained connect, the second when a floor-claimed destination has no live physical
    /// pin). Opening the rung on those sent
    /// DNS out the PHYSICAL interface because of a LOCAL condition, for the whole backoff window
    /// or the whole connect gap, while the upstream resolver had never been asked (adversarial
    /// review, PR #590).
    ///
    /// This is the same distinction PR #575 drew for the fallback counters, where counting local
    /// refusals made the panel report "your VPN isn't forwarding" after three queries that were
    /// never sent. `reachedTheWire` is that predicate; it belongs at this gate too.
    ///
    /// An error reply needs no such test — a reply is proof of the wire.
    /// pinned: ResolverOrchestratorTests.testALocalRefusalOfTierZeroDoesNotOpenThePhysicalRung
    private static func upstreamDeclinedToServe(_ result: DNSResolutionResult) -> Bool {
        guard let response = result.response else {
            return result.attempts.contains { $0.outcome.reachedTheWire }
        }
        return DNSResolverSmokeProbe.indicatesResolverFailure(response)
    }

    /// Stamps a T1 rung's primary result with its own outcome, before its fallback legs run.
    ///
    /// Gated on the rung rather than applied unconditionally so a `.planned` resolution carries
    /// nil — the field means "what the T1 SELECTION did", and a DNS-only resolution has no
    /// T1 selection to describe.
    private static func stampingTierOneSelectionOutcome(
        _ selection: DNSResolutionResult, rung: ResolutionRung
    ) -> DNSResolutionResult {
        guard case .tierOneFallback = rung else { return selection }
        return selection.stampingTierOneSelectionOutcome(Self.selectionOutcome(selection))
    }

    /// Classifies the T1 SELECTION alone, by the same three bars T0 is judged by.
    ///
    /// `reachedTheWire` is the attempt bar, and it is not a formality: counting local refusals as
    /// attempts once had the panel report "your VPN isn't forwarding" after three refusals that
    /// never left the device, sending users to configure an exit node they did not need
    /// (Codex, PR #575). A selection the allowance refused is exactly that shape, so it is `nil`
    /// here rather than `.attempted`.
    ///
    /// The reply bar is the one T0 has always applied to a resolver's reply: `.success`
    /// covers both served answers and resolver errors because the loop records both that way,
    /// `.truncatedAnswer` is the resolver correctly saying the answer does not fit UDP, and
    /// `.mismatchedResponse` is source-matched junk from the resolver itself. Off-source junk
    /// (`.unexpectedSourceResponse`) is deliberately NOT a reply.
    ///
    /// COMPUTED FROM THE SELECTION, NOT HANDED THE MERGE'S `served`, and that inversion is the
    /// fix. This classifier's predecessor took `served` from the merge, argued as keeping the
    /// counter and the answer the client received from ever disagreeing. They SHOULD disagree,
    /// and exactly when a fallback leg rescued the query: the client got an answer and the
    /// resolver the user chose still failed. Tying them together is what made a dead selection
    /// render as working (PR #606).
    private static func selectionOutcome(
        _ selection: DNSResolutionResult
    ) -> TierOneRungOutcome? {
        guard selection.attempts.contains(where: { $0.outcome.reachedTheWire }) else { return nil }
        if !Self.declinedToServe(selection) { return .served }
        let replied = selection.attempts.contains {
            $0.outcome == .success || $0.outcome == .truncatedAnswer
                || $0.outcome == .mismatchedResponse
        }
        return replied ? .answered : .attempted
    }

    /// Shares the primary/fallback health bar: only well-formed NOERROR or NXDOMAIN serves a query.
    private static func ladderServedTheClient(_ rung: DNSResolutionResult) -> Bool {
        DNSResolverSmokeProbe.indicatesServedAnswer(rung.response)
    }

    /// Missing, malformed, and error replies cannot serve the client. Valid NOERROR/NODATA
    /// and NXDOMAIN stay authoritative, including negatives from the upstream's private zone.
    /// pinned: ResolverOrchestratorTests.testAnAuthoritativeNegativeFromTierZeroIsNotSecondGuessed
    private static func declinedToServe(_ result: DNSResolutionResult) -> Bool {
        !DNSResolverSmokeProbe.indicatesServedAnswer(result.response)
    }

    /// Folds the T1 rung's outcome onto T0's, preserving BOTH sets of attempts.
    ///
    /// The attempts are the diagnostic: a field capture has to show that T0 was tried, what
    /// it said, and that the rung followed — collapsing to one set makes a rescue look like a
    /// resolution that never touched the tunnel.
    ///
    /// T0'S REAL ANSWER WINS WHEN THE RUNG SERVED NOTHING, which is the same rule the
    /// tunnelled loop already applies internally: a genuine SERVFAIL from the upstream is worth
    /// more to the client than a synthesized one, and the rung failing does not erase it.
    /// pinned: ResolverOrchestratorTests.testTheRungKeepsTierZerosAttemptsAndItsAnswerWhenNothingServed
    private static func merging(
        planned: DNSResolutionResult, rung: DNSResolutionResult, route: TunnelledPlainDNSRoute
    ) -> DNSResolutionResult {
        let attempts = planned.attempts + rung.attempts
        // `response != nil` IS NOT THE BAR: a T1 SERVFAIL or REFUSED is a packet, so it would
        // count as served and replace T0's real answer, resolver address and transport — with
        // a failure of exactly the class `declinedToServe` names (Codex, PR #590).
        //
        // THE ENTRY BAR AND THIS ONE ARE DELIBERATELY DIFFERENT, and an earlier version of this
        // comment claimed they were the same predicate. They were, until the rung's gate narrowed
        // to `upstreamDeclinedToServe` — which additionally requires a no-reply T0 result to
        // have REACHED THE WIRE, because a local refusal is no evidence the upstream declined
        // (Kilo, PR #590).
        //
        // THIS SIDE MUST KEEP THE BROADER PREDICATE. The questions differ: the gate asks "did the
        // UPSTREAM fail to serve", this asks "did the RUNG serve". Swapping this to the narrow one
        // would invert the answer for a rung that never reached the wire — refused by the
        // allowance, or handed a plan with nowhere to send — because `upstreamDeclinedToServe`
        // returns FALSE there, making `served` true and letting the rung's nil response displace
        // T0's real answer. The contract is still two halves; they are simply two questions
        // rather than one.
        let served = !Self.declinedToServe(rung)
        // Response selection and rescue credit share the same full-RCODE and structural bar.
        // The selection's own outcome remains separate because its configured T2 can rescue it.
        let ladderServedTheClient = Self.ladderServedTheClient(rung)
        return DNSResolutionResult(
            response: served ? rung.response : planned.response,
            successfulResolverAddress: served
                ? rung.successfulResolverAddress : planned.successfulResolverAddress,
            attempts: attempts,
            transport: served ? rung.transport : planned.transport,
            // TRUNCATION FOLLOWS THE ANSWER THE CLIENT ACTUALLY GOT, not "was truncation seen
            // anywhere". `||` was wrong twice over (Kilo, PR #590): T0 fails CLOSED on a
            // truncated answer, so the rung opens, and a complete rung answer came back flagged
            // truncated — which `ResolverHealthOrganicEvidence` turns into a
            // `udpTruncatedResponseCount` bump for a resolution that was never truncated.
            //
            // My justification for keeping it was also false: I wrote that the TCP-retry gate
            // reads this flag, and it does not — `shouldAttemptTCPFallback(afterUDPOutcome:)`
            // keys off the ATTEMPT OUTCOME. Nothing needed the union.
            //
            // The chained truncation counters are unaffected either way: the provider derives
            // them inside `resolveTunnelledPlainDNS` from the tunnelled verdict, before this
            // merge ever runs, so T0's `sawTruncation` is already recorded there.
            udpTruncated: served ? rung.udpTruncated : planned.udpTruncated,
            // THE TCP FLAGS UNION, AND DELIBERATELY DO NOT FOLLOW `served`. They are not a
            // description of the answer the client got — they are activity counters:
            // `ResolverHealthOrganicEvidence.applyAttemptMetrics` bumps
            // `tcpFallbackAttemptCount` once per resolution that attempted a TCP retry. A retry
            // that happened is a fact about the resolution regardless of which rung's answer
            // won, so losing T0's would undercount the transport we are trying to observe.
            // This is the same rule the sibling merge `withDeviceDNSFallback` applies.
            //
            // Today T0 can only contribute `false`: the tunnelled path has NO TCP rung at
            // all (`TunnelledPlainDNSResolution` — "No TCP retry", per the phase-3 plan's
            // resolved decision 3), so it hard-codes both flags false at every exit. The union
            // is therefore a no-op right now and is written for the invariant rather than for
            // today's arithmetic: if the tunnelled path ever gains a TCP retry, this site stays
            // correct without anyone remembering to come back to it.
            // pinned: ResolverOrchestratorTests.testTheRungUnionsTheTCPFlagsRatherThanFollowingTheServedAnswer
            tcpFallbackAttempted: planned.tcpFallbackAttempted || rung.tcpFallbackAttempted,
            tcpFallbackSucceeded: planned.tcpFallbackSucceeded || rung.tcpFallbackSucceeded,
            // THE RUNG'S OWN FALLBACK LEGS, split the same way the fields above are: the ones that
            // describe ACTIVITY union, the ones that describe THE ANSWER follow `served`.
            //
            // Dropped entirely until now, and the cost was a misattribution in health scoring —
            // the same defect PR #606 fixed for the panel, one layer down.
            // `ResolverHealthOrganicEvidence` branches on `usedEncryptedFallback` and
            // `deviceDNSFallbackSucceeded` to decide whether a resolution was a fallback or the
            // SELECTED resolver answering. With both false on every merged chained result, a
            // T1 selection that never answered was scored `.selectedResolver` every time its
            // own device or encrypted leg rescued the query — crediting a failing resolver with
            // healthy resolutions, which is exactly backwards for the user whose alternative DNS
            // is broken.
            //
            // `deviceDNSFallbackAttempted` and `deviceDNSUnavailable` UNION, because they are
            // facts about what the resolution did, true regardless of whose answer won — the same
            // reasoning as the TCP flags above.
            deviceDNSFallbackAttempted:
                planned.deviceDNSFallbackAttempted || rung.deviceDNSFallbackAttempted,
            // ...and these two FOLLOW `served`, because each says "this leg produced the selected
            // response". When the rung did not serve, T0's answer is the selected one and the
            // rung's leg produced nothing the client received, so carrying them would credit a
            // fallback for an answer that never left it.
            deviceDNSFallbackSucceeded:
                served ? rung.deviceDNSFallbackSucceeded : planned.deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: planned.deviceDNSUnavailable || rung.deviceDNSUnavailable,
            usedEncryptedFallback:
                served ? rung.usedEncryptedFallback : planned.usedEncryptedFallback,
            // THE SELECTION'S VERDICT, NOT THE LADDER'S, and the two genuinely differ. `served`
            // above decides what the CLIENT gets, and a rescue by the rung's own device or
            // encrypted leg is a perfectly good answer to hand back. The COUNTERS describe the
            // resolver the user chose, and by that measure the same query is a failure. Folding
            // both out of one verdict made a selection that answered nothing render as
            // `.working(rescues:)` (PR #606).
            //
            // Read from the stamp rather than recomputed here, because by this point the rung's
            // fallback attempts are already concatenated into `rung.attempts` and the boundary
            // is gone. See ``DNSResolutionResult/tierOneSelectionOutcome``.
            //
            // STAMPED WITH THE ROUTE'S SESSION, not with whatever session is live when this
            // result is finally consumed. See `TierOneRungEvidence`.
            // BUILT UNCONDITIONALLY, because this function runs only when a rung actually ran
            // (`merging` has one caller, inside the rung's own completion) and because the two
            // verdicts it carries fail at different times.
            //
            // IT USED TO BE `rung.tierOneSelectionOutcome.map { … }`, which dropped the WHOLE
            // evidence whenever the SELECTION never reached the wire — every T1 endpoint
            // `.backedOff`, or the rung's latch refusing the leg. That is exactly when the user's
            // configured T2 does the work, so the one shape where `ladderServed` matters most was
            // the one shape that could not report it, and repeated T0 misses still ran to
            // surrender while T2 answered every query (Codex P1, PR #639).
            //
            // `outcome` is therefore OPTIONAL rather than absent: nil means "the selection never
            // reached the wire", which is a real and different statement from `.attempted`, and
            // one the counters must keep honouring by moving nothing (PR #575 — a local refusal
            // counted as an attempt had the panel blame the peer for queries never sent).
            tierOneRung: TierOneRungEvidence(
                outcome: rung.tierOneSelectionOutcome,
                // THE LADDER'S VERDICT, alongside the selection's, and held to the bar the
                // CLIENT is held to — see `ladderServedTheClient` above.
                ladderServed: ladderServedTheClient,
                originatingLifecycle: route.originatingLifecycle,
                originatingLatchEpoch: route.originatingLatchEpoch),
            // CARRIED ONTO THE MERGED RESULT TOO, not just consumed into `tierOneRung` above.
            // This initializer is the one rebuild that does not copy its inputs field by field,
            // so leaving it out made the property nil on every result a caller actually receives
            // — while its own documentation promised the stamp survives every rebuild. A public
            // property that is always nil at the only point anyone can read it is worse than
            // absent: it reads as "no selection ran" (Codex P2, PR #606).
            tierOneSelectionOutcome: rung.tierOneSelectionOutcome,
            tierEvidence: planned.tierEvidence + rung.tierEvidence)
    }

    /// Which INTERFACE a plain resolution must leave on — the decision the SOCKET needs, and the
    /// one ``EgressAllowance`` does not answer.
    ///
    /// THESE ARE TWO DIFFERENT QUESTIONS AND CONFLATING THEM COST A SLICE. The allowance answers
    /// "may this transport leave on the physical interface"; the socket layer separately answers
    /// "which interface does this datagram go out of", and in the packet tunnel that second answer
    /// came from `currentResolverSocketBinding()`, which keys ONLY on whether chained mode is
    /// latched. So a rung the allowance had permitted onto the physical interface was still pinned
    /// to the tunnel by the socket, went to the peer, and timed out exactly as before — the very
    /// failure the T1 rung exists to remove (Codex, PR #590).
    ///
    /// `providerDefault` is the default parameter value on purpose, and the polarity is the
    /// opposite of the allowance's: silence here yields the RESTRICTIVE answer (the tunnel, while
    /// chained), so a caller that forgets to think about it cannot leak. Only the T1 rung asks
    /// for `physical`, and it does so explicitly.
    public enum EgressInterface: Sendable, Equatable {
        /// Whatever the provider's mode says: the tunnel while chained, the routing table
        /// otherwise. Every caller that existed before the T1 rung.
        case providerDefault
        /// The physical interface, explicitly, whatever the latched mode says. The chained T1
        /// rung, which exists precisely to leave the tunnel.
        case physical
    }

    /// What the chained T1 rung did, in the three terms the settings panel counts.
    ///
    /// Deliberately the SAME nesting the T0 fallback counters already use — served ⊆ answered
    /// ⊆ attempted — so the panel's existing verdicts keep their meaning when the evidence starts
    /// arriving from the physical rung instead of from the tunnelled route. `ChainedFallbackStatus`
    /// distinguishes "tried and nothing came back" from "replied but did not help" from "working",
    /// and it can only do that if all three terms are supplied.
    public enum TierOneRungOutcome: String, Sendable, Equatable {
        /// A datagram left the device and nothing usable came back — the shape that, repeated, is
        /// the peer-not-forwarding verdict.
        case attempted
        /// The resolver replied with an error RCODE or unusable packet. This proves
        /// reachability without claiming that the name was served.
        case answered
        /// The resolver served the name. This is the rescue the whole feature exists for, and the
        /// counter rc10 has to see move.
        case served
    }

    /// The rung's outcome STAMPED WITH THE SESSION IT RAN UNDER.
    ///
    /// THE TOKENS TRAVEL WITH THE EVIDENCE, and re-deriving them at completion is not equivalent —
    /// it is a guard that cannot fail. The provider used to fetch the CURRENT route when the rung
    /// finished and compare its tokens against the current lifecycle, which they equal by
    /// construction. A rung admitted under session A and completing after session B started would
    /// therefore land A's rescue in B's counters and B's energy numerator, exactly the
    /// cross-lifecycle contamination the per-session reset exists to prevent and that T0's own
    /// guard does prevent (Codex, PR #590; the same defect class as PR #520).
    ///
    /// Stamped from the tunnelled route the rung was opened against, which is the session that
    /// admitted the work — the same token pair `TunnelledPlainDNSRoute` already carries for T0.
    public struct TierOneRungEvidence: Sendable, Equatable {
        /// The SELECTION's own verdict, or `nil` when it never reached the wire.
        ///
        /// Nil is a statement, not an absence: every endpoint `.backedOff`, or a mid-ladder
        /// relatch refusing the leg, means the resolver the user chose was never asked. The
        /// counters must move for none of it (PR #575), while ``ladderServed`` can still be true
        /// — that is precisely the case where the user's configured T2 carried the query.
        public let outcome: TierOneRungOutcome?
        /// Whether the RUNG AS A WHOLE served the name — its own T2 legs included.
        ///
        /// THE SECOND HALF OF THE SPLIT ``outcome`` DOCUMENTS, and the reason both are carried.
        /// `outcome` is the SELECTION's verdict: it answers "did the resolver the user chose
        /// serve this", which is the right question for the counters and the wrong one for
        /// anything asking whether the USER got an answer. When T1 is dark and the user's own T2
        /// rescues the query, `outcome` is `.attempted` and the client still receives a real
        /// answer. This flag is that fact.
        ///
        /// Uses the same service bar as response selection: a structurally valid NOERROR
        /// or NXDOMAIN reply, classified using the full 12-bit RCODE.
        ///
        /// Read it as "the rung was not a blackhole", never as "T1 is healthy" — the outage
        /// driver credits on THIS (`ChainedOutageDriver.reportTierOneRungRescue`), because a
        /// user whose T2 answered was no more blackholed than one whose T1 did, and the tiers
        /// below T1 are the fallback the user configured precisely so that they would answer.
        public let ladderServed: Bool
        /// The lifecycle generation the rung was admitted under.
        public let originatingLifecycle: UInt64
        /// The data-path latch epoch the rung was admitted under.
        public let originatingLatchEpoch: UInt64

        public init(
            outcome: TierOneRungOutcome?, ladderServed: Bool,
            originatingLifecycle: UInt64, originatingLatchEpoch: UInt64
        ) {
            self.outcome = outcome
            self.ladderServed = ladderServed
            self.originatingLifecycle = originatingLifecycle
            self.originatingLatchEpoch = originatingLatchEpoch
        }
    }

    /// Which rung of the chained ladder a resolution is serving.
    ///
    /// A type rather than a Bool because the two rungs differ in WHICH ALLOWANCE governs them,
    /// and carrying the allowance in the case makes it impossible to be on the T1 rung
    /// without one. The T1 allowance is derived (``EgressAllowance/tierOneFallbackAllowance``)
    /// and its own T1 flag is false, so `.tierOneFallback` cannot produce another rung —
    /// the recursion below terminates structurally rather than by a depth counter.
    private enum ResolutionRung: Sendable {
        /// The ordinary path: consults the tunnelled route while chained, and is governed by the
        /// orchestrator's own allowance.
        case planned
        /// The chained T1 rung, on the PHYSICAL interface, under the derived allowance. Never
        /// consults the tunnelled route — T0 has already been tried and did not serve.
        ///
        /// CARRIES THE LATCH INSTALL IT WAS ADMITTED UNDER, and that token is what fences the
        /// rung's egress against a relatch. `admittedAtEpoch` names the tunnel LIFECYCLE, which a
        /// relatch does not move, so none of the `admissionIsCurrent` guards fire for one. T0
        /// is covered because ``TunnelledPlainDNSRoute`` seals its own latch epoch and the
        /// executor validates it per attempt; the rung's plan is a bare ``DNSResolverRuntimePlan``
        /// with no such token, so a plan obtained before a relatch could still egress after it —
        /// sending T1 lookups to the device resolver the user had just switched OFF
        /// (Codex P2, PR #599 → PR #608).
        ///
        /// ON THE RUNG rather than as a parallel parameter beside `admittedAtEpoch`, because the
        /// rung is ALREADY threaded through every site that one is. A second `UInt64` argument
        /// would have to be added and correctly forwarded at ~29 call sites, each an opportunity
        /// to drop it silently; this cannot be forgotten at a call site because there is no call
        /// site to forget it at.
        case tierOneFallback(EgressAllowance, originatingLifecycle: UInt64, admittedAtLatchEpoch: UInt64)

        func allowance(_ orchestratorAllowance: @Sendable () -> EgressAllowance) -> EgressAllowance {
            switch self {
            case .planned:
                return orchestratorAllowance()
            case .tierOneFallback(let allowance, _, _):
                return allowance
            }
        }

        /// The latch install this rung was admitted under, or `nil` for `.planned`.
        var admittedAtLatchEpoch: UInt64? {
            switch self {
            case .planned: return nil
            case .tierOneFallback(_, _, let epoch): return epoch
            }
        }

        var originatingLifecycle: UInt64? {
            switch self {
            case .planned: return nil
            case .tierOneFallback(_, let lifecycle, _): return lifecycle
            }
        }

        var consultsTunnelledRoute: Bool {
            switch self {
            case .planned: return true
            case .tierOneFallback: return false
            }
        }

        /// The socket-level half of the rung's egress decision. The allowance says whether the
        /// rung may leave physically; this says the datagram actually does.
        var egressInterface: EgressInterface {
            switch self {
            case .planned: return .providerDefault
            case .tierOneFallback: return .physical
            }
        }
    }

    private func resolvePrimaryUpstream(
        _ query: Data,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool,
        admittedAtEpoch: UInt64,
        rung: ResolutionRung = .planned,
        tier: DNSResolverTier,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        // Ahead of the egress allowance, because "who is asking" precedes "may they egress":
        // a resolution whose session ended has no business consulting a latch that now
        // belongs to someone else. This also covers the plain, device and tunnelled routes
        // below — every transport, not only the pooled ones the endpoint ladder serves.
        guard admissionIsCurrent(admittedAtEpoch) else {
            completion(staleLifecycleResult(for: plan))
            return
        }

        let allowance = rung.allowance(egressAllowance)

        // T0 WHILE CHAINED, ahead of the transport switch and ahead of the encrypted refusal
        // below — because while chained the upstream's own `DNS =` IS the primary, whatever
        // transport the user picked. Their selection is the T1 rung, tried only for a name
        // T0 did not serve.
        //
        // THE HOIST IS THE POINT, and it fixes a blackhole. The consult used to live inside the
        // `.plainDNS` / `.deviceDNS` arms only, so a chained user whose preset was encrypted was
        // refused by the guard below and never reached the tunnel at all — every query answered
        // SERVFAIL with the upstream's own resolver sitting there, willing and unasked.
        //
        // THE RUNG FIRES ON A NON-ANSWER, NOT ON A NEGATIVE. `indicatesResolverFailure`
        // or no response at all: those are T0 declining to serve.
        // NXDOMAIN and NODATA are deliberately NOT here — they are authoritative answers, and
        // re-asking a public resolver about a name the upstream's own resolver just answered
        // negatively is how a split-DNS name gets a stranger's NXDOMAIN instead of its real
        // negative (the failure PR #589 reverted). A resolver that is authoritative for its own
        // zone and answers every public name NXDOMAIN is a real shape, but it is indistinguishable
        // at the wire from a genuine negative, so it is left to field evidence rather than
        // guessed at here.
        // pinned: ResolverOrchestratorTests.testASplitTunnelTierOneRungRunsOnThePhysicalInterface
        // pinned: ResolverOrchestratorTests.testAnAuthoritativeNegativeFromTierZeroIsNotSecondGuessed
        if rung.consultsTunnelledRoute, let route = tunnelledPlainDNSRoute() {
            let observationPathEpoch = currentPathEpoch()
            let rawPlanned = executors.resolveTunnelledPlain(query, route)
            let planned = rawPlanned.appendingTierEvidence(ResolverTierEvidence(
                tier: .tierZero, resolverKind: .upstream, egress: .tunnel,
                result: rawPlanned, originatingLifecycle: route.originatingLifecycle,
                originatingLatchEpoch: route.originatingLatchEpoch,
                observationPathEpoch: observationPathEpoch))
            // THREE INDEPENDENT CONDITIONS, and each one alone is a reason to stop at T0:
            // T0 actually served the name; the route plan is full-tunnel so no physical
            // egress is permitted at all; or this session has no rung to run.
            //
            // THE PLAN COMES FROM THE PROVIDER, NOT FROM `plan`. Re-resolving the caller's own
            // plan here made the rung's existence a property of T0's configuration, so a
            // physical-interface lookup happened whether or not one was warranted (Codex, PR
            // #590). `tierOneFallbackPlan()` answering nil is the no-rung case, and it fails
            // closed onto T0's own answer.
            // pinned: ResolverOrchestratorTests.testNoRungRunsWhenTheUserHasNotOptedIntoATierOneFallback
            // pinned: ResolverOrchestratorTests.testTheRungResolvesTheAlternativePlanRatherThanThePrimary
            guard Self.upstreamDeclinedToServe(planned),
                let rungAllowance = allowance.tierOneFallbackAllowance,
                let rungPlan = tierOneFallbackPlan()
            else {
                completion(planned)
                return
            }
            // `resolveUpstream`, NOT `resolvePrimaryUpstream`, and that one word is the fix.
            // `resolvePrimaryUpstream` runs "only the plan's primary route, including ordered
            // endpoint failover but no cross-route fallback" — its own words. Dispatching the
            // rung there gave a chained user's second opinion one route and no ladder, while the
            // identical DNS-only query got the device and encrypted fallbacks below. It is also
            // why clearing `fallbackToDeviceDNS` on the rung's configuration was inert (PR #593,
            // reverted in `c1b0fc7`): the flag is read here, on a path the rung never entered.
            // One cause, two symptoms.
            //
            // No recursion, and it is structural rather than a counter: this call re-enters
            // `resolvePrimaryUpstream` carrying `.tierOneFallback`, whose `consultsTunnelledRoute`
            // is false, so the T0 block above is not re-entered and no rung can spawn a rung.
            // `tierOneFallbackAllowance` independently sets
            // `permitsTierOneFallbackOnPhysicalInterface: false` as the second lock.
            // pinned: ResolverOrchestratorTests.testTheTierOneRungRunsTheFullFallbackLadder
            resolveUpstream(
                query,
                plan: rungPlan,
                usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections,
                admittedAtEpoch: admittedAtEpoch,
                // SEALED FROM THE ROUTE THAT OPENED THIS RUNG. The route's addresses and both its
                // tokens are derived in ONE provider critical section, so the epoch is a coherent
                // reading of the data path as of that call.
                //
                // NOT the same read as `rungPlan`, and the first version of this comment claimed
                // it was. `tunnelledPlainDNSRoute()` and `tierOneFallbackPlan()` are two separate
                // closures with their own critical sections, so a relatch between them yields a
                // plan NEWER than the sealed epoch (Kilo, PR #608). That direction is the safe
                // one — live epoch > sealed epoch refuses — so the fence still fails closed; but
                // the guarantee is "the epoch is the route's, read atomically with its own
                // addresses", not "it names the exact install the plan came from".
                rung: .tierOneFallback(
                    rungAllowance, originatingLifecycle: route.originatingLifecycle,
                    admittedAtLatchEpoch: route.originatingLatchEpoch)
            ) { rungResult in
                completion(Self.merging(planned: planned, rung: rungResult, route: route))
            }
            return
        }

        // Encrypted transports refused before their executors are reached. Each opens its own
        // TCP/QUIC connection on the ordinary physical interface, which while chained is the
        // interface the tunnel routed everything away from — so a configured DoH primary leaks
        // exactly as device DNS does, and less visibly.
        //
        // Answered, not dropped: INV-DNS-1 is about never failing OPEN, and an unanswered query
        // times out indistinguishably from a network problem and invites a retry into the same
        // refusal.
        if !allowance.permits(plan.transport) {
            switch plan.transport {
            case .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC:
                // An attempt record, not an empty array. `failureSummary` reads
                // `attempts.last?.outcome`, and the smoke-probe log renders
                // `failureSummary ?? "success"` — so no attempts meant a refusal that prevents
                // a DNS leak was logged as a successful resolution, and the evidence recorder
                // saw `.totalFailure(reason: nil)`. The identity of the refused resolver
                // matters too: "which endpoint did we decline, and why" is the whole
                // diagnostic.
                completion(
                    DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [
                            ResolverAttempt(
                                address: Self.refusedEndpointIdentity(for: plan),
                                outcome: .refusedByEgressPolicy,
                                transport: plan.transport)
                        ],
                        transport: plan.transport,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false))
                return
            case .plainDNS, .deviceDNS:
                break
            }
        }

        switch plan.transport {
        case .dnsOverHTTPS:
            guard !plan.dohEndpoints.isEmpty else {
                resolvePlainWithinAllowance(
                    query, plan: plan, admittedAtEpoch: admittedAtEpoch, rung: rung,
                    completion: completion)
                return
            }

            resolveEndpoints(
                query,
                endpoints: plan.dohEndpoints,
                transport: .dnsOverHTTPS,
                index: plan.dohEndpoints.startIndex,
                previousAttempts: [],
                admittedAtEpoch: admittedAtEpoch,
                rung: rung,
                resolveEndpoint: { query, endpoint, completion in
                    executors.resolveDoH(query, endpoint, rung.admittedAtLatchEpoch, completion)
                },
                cacheIdentifier: { $0.cacheIdentifier },
                completion: completion
            )

        case .dnsOverTLS:
            guard !plan.dotEndpoints.isEmpty else {
                resolvePlainWithinAllowance(
                    query, plan: plan, admittedAtEpoch: admittedAtEpoch, rung: rung,
                    completion: completion)
                return
            }

            resolveEndpoints(
                query,
                endpoints: plan.dotEndpoints,
                transport: .dnsOverTLS,
                index: plan.dotEndpoints.startIndex,
                previousAttempts: [],
                admittedAtEpoch: admittedAtEpoch,
                rung: rung,
                resolveEndpoint: { query, endpoint, completion in
                    executors.resolveDoT(
                        query, endpoint, usesIsolatedEncryptedConnections,
                        rung.admittedAtLatchEpoch, completion)
                },
                cacheIdentifier: { $0.cacheIdentifier },
                completion: completion
            )

        case .dnsOverQUIC:
            guard !plan.doqEndpoints.isEmpty else {
                resolvePlainWithinAllowance(
                    query, plan: plan, admittedAtEpoch: admittedAtEpoch, rung: rung,
                    completion: completion)
                return
            }

            resolveEndpoints(
                query,
                endpoints: plan.doqEndpoints,
                transport: .dnsOverQUIC,
                index: plan.doqEndpoints.startIndex,
                previousAttempts: [],
                admittedAtEpoch: admittedAtEpoch,
                rung: rung,
                resolveEndpoint: { query, endpoint, completion in
                    executors.resolveDoQ(
                        query, endpoint, usesIsolatedEncryptedConnections,
                        rung.admittedAtLatchEpoch, completion)
                },
                cacheIdentifier: { $0.cacheIdentifier },
                completion: completion
            )

        case .plainDNS:
            // The tunnelled carry no longer lives here: it was HOISTED above the transport
            // switch, so T0 runs for every transport rather than only for this arm and its
            // `.deviceDNS` sibling. Reaching this line therefore means one of two things — no
            // tunnelled route (DNS-only, or a chained session whose route derivation disagreed
            // with the readiness gate that admitted it), or this IS the T1 rung, running on
            // the physical interface under the derived allowance.
            //
            // Both are answered by the allowance below and behave exactly as they always have:
            // resolved on the physical interface where permitted, refused fail-closed where not.
            // Answered, not dropped — INV-DNS-1 is about never failing OPEN, and an unanswered
            // query times out indistinguishably from a network fault and invites a retry into
            // the same refusal.
            resolvePlainWithinAllowance(
                query, plan: plan, admittedAtEpoch: admittedAtEpoch, rung: rung,
                completion: completion)

        case .deviceDNS:
            // The tunnelled carry for device DNS is the HOISTED consult above, not a block here.
            // While chained, a device-DNS primary rides the session to the upstream's own
            // resolver rather than egressing on the physical interface — device-verified
            // (chimmy, 2026-08-14): the app DEFAULTS to device DNS, so without the carry a
            // chained user with no plain/encrypted resolver configured saw a total DNS
            // blackhole, device DNS refused just below with nothing to take its place.
            //
            // Reaching this line while chained therefore means the T1 RUNG — and the rung
            // now PERMITS device DNS, when the user's one resolver selection is device DNS.
            //
            // IT USED TO REFUSE IT, on the reasoning that the rung is the resolver the user chose
            // and never the one DHCP handed them (`LAV-87`). That conflated two different acts.
            // A device-wide fallback EPISODE rewriting the rung into a device-DNS plan is still
            // forbidden — `ignoresDeviceDNSFallbackMode: true` at the plan site is what forbids
            // it. A user who SELECTED Device DNS is a different case: they already send every
            // DNS-only query there, Lava's blocklist still runs before the upstream query, and
            // the profile this whole feature exists for — Tailscale MagicDNS with no global
            // nameservers — falls through to exactly those resolvers natively. Refusing it left
            // a chained user strictly worse off than not chaining at all (founder, 2026-08-27).
            //
            // The guard below still stands, and still matters: under the PRIMARY allowance while
            // chained (`chainedMode` / `chainedSplitTunnelMode`) `permitsDeviceDNS` is false, so
            // a T0 device-DNS resolution that reaches here without a tunnelled route is
            // refused exactly as before. Device DNS as T0 while chained IS the leak: it
            // egresses on the interface the tunnel routed everything away from, and nothing
            // breaks visibly when it happens.
            //
            // INV-DNS-1 is about never failing OPEN, which means a refused query still gets an
            // ANSWER. Leaving it unanswered would time out, be indistinguishable from a network
            // problem, and invite a retry against the same refusal.
            // pinned: ResolverOrchestratorTests.testChainedModeCarriesADeviceDNSPrimaryThroughTheTunnelWhenARouteExists
            // pinned: ResolverOrchestratorTests.testTheRungResolvesADeviceDNSSelectionOnThePhysicalInterface
            guard allowance.permits(.deviceDNS) else {
                // NOT `deviceDNSUnavailable`. That flag was minted for "no captured resolver
                // address was available", and a diagnostic that conflates a policy refusal with
                // a missing resolver misleads whoever reads the next field report — one is the
                // tunnel working as designed, the other is a configuration failure.
                completion(
                    DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [
                            ResolverAttempt(
                                address: plan.plainAddresses.first ?? "device-dns",
                                outcome: .refusedByEgressPolicy,
                                transport: .deviceDNS)
                        ],
                        transport: .deviceDNS,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false))
                return
            }
            completion(
                executors.resolveDevice(
                    query, plan.plainAddresses, admittedAtEpoch,
                    rung.admittedAtLatchEpoch, rung.egressInterface, tier))
        }
    }

    // Endpoint failover: each endpoint gets one shot (the transports handle
    // their own bootstrap/retry internally). Healthy alternatives come first. If all
    // endpoints are suppressed, the shared backoff owner may grant one recovery launch;
    // every other suppressed endpoint records a non-wire attempt.
    private func resolveEndpoints<Endpoint: Sendable>(
        _ query: Data,
        endpoints: [Endpoint],
        transport: DNSResolverTransport,
        index: Array<Endpoint>.Index,
        previousAttempts: [ResolverAttempt],
        admittedAtEpoch: UInt64,
        rung: ResolutionRung,
        resolveEndpoint: @escaping @Sendable (Data, Endpoint, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
        cacheIdentifier: @escaping @Sendable (Endpoint) -> String,
        recoveryEndpoint: String? = nil,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        // THE SITE THE P1 NAMED, and the reason the check belongs per RUNG rather than only at
        // entry: this function re-enters itself once per endpoint, and every re-entry is a
        // fresh admission decision made after a wire attempt that took real time. A tunnel
        // that stopped during rung 1 must not have rung 2 opened on its behalf — which is
        // exactly what a cancelled lane's late `.receiveFailed` was doing, since a nil
        // response is the signal to walk on.
        //
        // The remaining endpoints are ABANDONED rather than walked and refused one by one:
        // they would each produce the same refusal, and a ladder of them says nothing the
        // first does not. `previousAttempts` is preserved so the rungs that really ran are
        // still in the record.
        guard admissionIsCurrent(admittedAtEpoch) else {
            completion(DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: previousAttempts + [
                    ResolverAttempt(
                        address: endpoints.indices.contains(index)
                            ? cacheIdentifier(endpoints[index])
                            : transport.rawValue,
                        outcome: .refusedAfterLifecycleEnded,
                        transport: transport)
                ],
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
            return
        }

        // AND THE LATCH, ONCE PER ENDPOINT, for exactly the reason the guard above is here rather
        // than only at entry. This ladder re-enters itself per endpoint and each iteration follows
        // a wire attempt that took real time — a DoH/DoT/DoQ list can spend seconds walking — so a
        // relatch landing mid-walk would otherwise send the NEXT endpoint from a plan the user has
        // already replaced. Guarding only before the ladder starts, which is what the first cut
        // did, left every endpoint after the first unfenced (Codex P2, PR #608).
        //
        // NO ATTEMPT IS APPENDED, unlike the lifecycle refusal above. Nothing was sent, and a
        // recorded attempt would let the panel count a query the device never made — the PR #575
        // failure this whole area exists to avoid. Abandoning also matches that refusal's shape:
        // the remaining endpoints would each answer identically, so one refusal says everything a
        // ladder of them would.
        //
        // `previousAttempts` is preserved, so the endpoints that really ran stay in the record,
        // and a T1 rung's result always merges onto T0's attempts — so this can never
        // produce the attempt-less result whose `failureSummary` would render as a success.
        //
        // A no-op for `.planned`: it carries no latch token, so DNS-only ladders are untouched.
        guard rungLatchIsCurrent(rung) else {
            completion(DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: previousAttempts,
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
            return
        }

        guard endpoints.indices.contains(index) else {
            completion(DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: previousAttempts,
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
            return
        }

        // Claim only at ladder entry. A failed recovery must not open every suppressed endpoint.
        // pinned: ResolverOrchestratorTests.testAllSuppressedEncryptedSelectionsLaunchOnlyOneEndpointPerInterval
        let recoveryEndpoint = index == endpoints.startIndex
            ? executors.claimEncryptedRecovery(endpoints.map(cacheIdentifier)) : recoveryEndpoint
        let endpoint = endpoints[index]
        let resolverAddress = cacheIdentifier(endpoint)

        let continueOrFinish: @Sendable (DNSResolutionResult) -> Void = { result in
            guard result.response == nil, index < endpoints.index(before: endpoints.endIndex) else {
                // Checked on the TERMINAL path too, not only when advancing. The re-entry
                // guard at the top of this function never runs for the last rung, so a
                // resolution whose session ended during its final endpoint handed a live
                // result straight back to its caller — and `resolvePrimaryUpstream` is public:
                // the smoke probe calls it directly and schedules its own device-DNS fallback
                // from that completion, consulting only the egress allowance. A's late failed
                // probe could therefore issue a device query during B (Codex P1, PR #524).
                //
                // The result is REPLACED rather than passed through, because a caller outside
                // `resolveUpstream` reads it to decide what to do next; handing back a real
                // failure invites exactly the follow-on work this refuses.
                guard self.admissionIsCurrent(admittedAtEpoch) else {
                    completion(DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: result.attempts + [
                            ResolverAttempt(
                                address: transport.rawValue,
                                outcome: .refusedAfterLifecycleEnded,
                                transport: transport)
                        ],
                        transport: transport,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false))
                    return
                }
                completion(result)
                return
            }

            self.resolveEndpoints(
                query,
                endpoints: endpoints,
                transport: transport,
                index: endpoints.index(after: index),
                previousAttempts: result.attempts,
                admittedAtEpoch: admittedAtEpoch,
                rung: rung,
                resolveEndpoint: resolveEndpoint,
                cacheIdentifier: cacheIdentifier,
                // Consume the grant at its first matching entry, including duplicate identifiers.
                recoveryEndpoint: resolverAddress == recoveryEndpoint ? nil : recoveryEndpoint,
                completion: completion
            )
        }

        guard resolverAddress == recoveryEndpoint || !executors.isEndpointBackedOff(resolverAddress) else {
            continueOrFinish(DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: previousAttempts + [
                    ResolverAttempt(
                        address: resolverAddress,
                        outcome: .backedOff,
                        transport: transport
                    )
                ],
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
            return
        }

        resolveEndpoint(query, endpoint) { upstreamResponse in
            let attempt = ResolverAttempt(
                address: resolverAddress,
                outcome: ResolverAttemptOutcome(upstreamResponse.outcome),
                transport: transport,
                negotiatedDoHProtocol: upstreamResponse.negotiatedHTTPProtocolName
            )

            continueOrFinish(DNSResolutionResult(
                response: upstreamResponse.response,
                successfulResolverAddress: upstreamResponse.response == nil ? nil : resolverAddress,
                attempts: previousAttempts + [attempt],
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
        }
    }
}
