import Foundation
import LavaSecKit

/// The session behaviour the driver depends on.
///
/// A protocol rather than the concrete runner, for two reasons that point the same way. The
/// driver has no business knowing how a session is CONSTRUCTED — that needs an endpoint, a
/// socket and key material, none of which are its concern — and a driver wired to a concrete
/// runner cannot be tested without standing up a real engine for every question about the
/// budget. `ChainedSessionRunner` conforms as it stands.
/// What replacing a session's transport achieved. Stable identifiers, never user copy.
public enum ChainedRebindOutcome: Equatable, Sendable {
    /// Swapped, and a keepalive went out on the existing keypair.
    case rebound
    /// Swapped, but NO KEYPAIR IS CURRENT, so nothing was probed — `encapsulate` would have
    /// queued an empty packet and emitted a handshake instead. The caller must rebuild rather
    /// than wait for a confirmation that cannot arrive.
    case noCurrentSession
    /// Not swapped. The runner is shut down or ended, or a send is on the stack.
    case refused
}

public protocol ChainedSessionDriving: AnyObject, Sendable {
    /// Replaces the transport, preserving the engine. Engine queue only.
    func adoptChannel(_ channel: ChainedUpstreamDatagramChannel) -> ChainedRebindOutcome
    func handleOutboundBatch(_ packets: [Data], protocols: [NSNumber])
    /// Sends a provider DNS packet directly, without opening a kernel route into this tunnel.
    /// False means no packet was retained and the caller may retry within its deadline.
    func sendResolverPacket(_ packet: Data, deadline: MonotonicDeadline) -> Bool
    func tick()
    func forceHandshake()
    func takeLivenessSample() -> ChainedLivenessSample
    /// The engine's cumulative transport byte totals, or `nil` when no session is current. Engine
    /// queue only, like the rest of this protocol.
    func sampleStatistics() -> ChainedRunnerStatistics?
    /// The store generation this runner's key material came from. Immutable and infallible —
    /// deliberately NOT part of `sampleStatistics()`, whose engine read can throw and would then
    /// make a live runner indistinguishable from none (Codex P2, PR #613).
    var acceptedUpstreamGeneration: UInt64 { get }
    /// The runner's data-path tallies. The driver folds them into its own counters when it
    /// retires a runner — a per-runner counter resets with its session, and the 60 s liveness
    /// line is only differenceable if the surfaced totals stay monotonic across rebuilds.
    func snapshotCounters() -> ChainedRunnerCounters
    func shutdown()
}

extension ChainedSessionRunner: ChainedSessionDriving {}

extension ChainedSessionDriving {
    /// Test and alternative runners without direct DNS support refuse rather than bypass the VPN.
    public func sendResolverPacket(_ packet: Data, deadline: MonotonicDeadline) -> Bool { false }
}

/// Where a new session comes from. The driver's ENTIRE knowledge of the transport.
///
/// It builds the runner rather than handing back parts, because everything the construction
/// needs — endpoint, channel, keys, AllowedIPs — belongs to the layer that owns the transport,
/// and passing them through the driver would make it the one object that has to know all of
/// them.
///
/// The contract that is not enforceable here: this must not block the engine queue. A blocking
/// implementation produces a blackhole the armed watchdog cannot bound, because the watchdog's
/// handler is enqueued behind it on this same serial queue and its deadline is the outage
/// deadline itself — so the surrender it exists to deliver is late by however long the build
/// stood still.
///
/// It is a real obligation and not a hypothetical one: `ChainedUpstreamSessionFactory` broke it
/// on arrival by reading the live interface list through a monitor it started and awaited per
/// build (PR #484). It holds now because that read is a cache copy whose filling wait is enforced
/// off this queue (`ChainedEngineQueue.requireOffQueue`), and because the endpoint is already
/// resolved before the driver runs. `ChainedUpstreamSessionFactory`'s `readCredentials` closure
/// runs here too, and stopped resting on prose when a real Keychain store filled it: the
/// production closure wraps its read in `ChainedBoundedCredentialRead`, so this queue waits at
/// most the bound — never on securityd (Codex, PR #508). Endpoint re-resolution is where the
/// contract comes under pressure again — that is the endpoint slice's problem, recorded here
/// rather than pre-solved.
///
/// A source that throws is ordinary, and what it costs depends on WHAT it threw. A
/// `ChainedSessionBuildFailure` the factory diagnosed as transient
/// (`warrantsAnotherAttempt`) spends one ladder rung, like a handshake that did not complete.
/// Everything else — a permanent build failure, and any error this module cannot triage, which
/// includes whatever a secret store throws — funnels to
/// `ChainedSessionEndCause.sessionCreationFailed`, which `ChainedReconnectPolicy` answers with
/// `.fallBackToDNSOnly(.engineUnusable)`: not a spent rung, the end of chaining for the lifecycle.
///
/// So "anything a source can fail on transiently had better be arranged not to" is no longer the
/// whole rule, but it still holds for anything the source cannot express as a triaged build
/// failure. That was the previous text, written when EVERY failure surrendered.
/// pinned: ChainedOutageDriverTests.testASessionThatFailsToBuildSurrendersInsteadOfSpendingARung
/// pinned: ChainedOutageDriverTests.testATransientBuildFailureSpendsARungRatherThanSurrendering
public protocol ChainedSessionSource: AnyObject, Sendable {
    /// Builds a REPLACEMENT transport for a session that is still alive.
    ///
    /// Same no-blocking contract as ``makeSession(engineQueue:events:)``: called inline on the
    /// engine queue, and must not wait on a path monitor.
    func makeChannel(engineQueue: ChainedEngineQueue) throws -> ChainedUpstreamDatagramChannel
    func makeSession(
        engineQueue: ChainedEngineQueue,
        events: ChainedSessionEvents
    ) throws -> ChainedSessionDriving
}

/// What the driver reports about itself. Not user copy.
public struct ChainedDriverCounters: Equatable, Sendable {
    /// Outages begun since this driver was created.
    public var outageCount = 0
    /// Attempts the supervisor authorized and this driver started.
    public var startedAttemptCount = 0
    /// Attempts refused because a ticket was stale or one was already running.
    public var stoodDownCount = 0
    /// Sessions that ended, however they ended.
    public var sessionEndCount = 0
    /// Times the monitored path went unsatisfied and the driver quiesced.
    ///
    /// Read alongside ``outageCount``: an outage count that tracks this one is a device with a
    /// flapping network, not a failing upstream, and the two want completely different fixes.
    public var offlinePathCount = 0
    /// Times a path came back, or changed interfaces, and the driver re-armed.
    public var pathRecoveryCount = 0
    /// Transports swapped under a live session — the R2 fast path, which costs no ladder rung.
    public var rebindCount = 0
    /// Path changes where the fast path was refused and the full ladder ran instead.
    public var rebindDeclinedCount = 0
    /// Rebinds that swapped but never proved themselves — not even after the one re-anchor retry —
    /// and fell back to a full rebuild.
    ///
    /// Read against ``rebindCount``: a ratio near 1 means the fast path is swapping onto sockets
    /// that do not work, which is worse than not having it.
    public var rebindUnconfirmedCount = 0
    /// Lone rebinds that missed the first confirmation window and were granted ONE more bounded
    /// re-anchor (a forced handshake + a fresh window) before any rebuild. A retry that then
    /// confirms saves the expensive full rebuild — a fresh handshake and connect-gate
    /// establishment — that a single lost re-anchor keepalive used to cost on a healthy path
    /// (device evidence: a real roam hit ``rebindUnconfirmedCount``→``outageCount`` and blackholed
    /// the App Store, 2026-08-23). Read against ``rebindUnconfirmedCount``: a large gap means the
    /// retry is absorbing transient losses; a ratio near 1 means the paths were genuinely dead and
    /// the retry only delayed their rebuild by one window.
    public var rebindReanchorRetryCount = 0
    /// Path transitions whose SOCKET recovery was coalesced into the settle window (C5).
    ///
    /// Read against ``pathRecoveryCount``, which keeps counting every observed transition: a
    /// large coalesced share means a flapping network whose socket churn the settle window is
    /// absorbing — the diagnostic pair stays honest because the observation counter and the
    /// build rate are no longer the same number.
    public var coalescedPathRecoveryCount = 0
    /// Tunnel-DNS resolutions reported answered (S6) — a TC answer included.
    public var tunnelDNSAnsweredObservationCount = 0
    /// Tunnel-DNS resolutions reported sent-and-unanswered (S6).
    ///
    /// Read against ``tunnelDNSAnsweredObservationCount``: a high unanswered share with a
    /// LOW ``tunnelDNSOutageCount`` means single-name failures the two-name floor is
    /// correctly refusing to escalate — one broken domain, not a dead resolver.
    public var tunnelDNSUnansweredObservationCount = 0
    /// Physical T1 rung rescues that disarmed the tunnel-DNS cause (S6).
    ///
    /// Read against ``tunnelDNSUnansweredObservationCount``: the two moving together with
    /// ``tunnelDNSOutageCount`` FLAT is a split-tunnel T0 that answers only its own names while
    /// the rung serves the rest — working as designed, not a fault. The same pair with
    /// ``tunnelDNSOutageCount`` climbing was the 2026-09-01 defect, and this counter exists so
    /// that shape is legible in a field capture rather than inferred from its absence.
    public var tierOneRungRescueObservationCount = 0
    /// Outages the tunnel-DNS cause declared (S6). A subset of ``outageCount``.
    public var tunnelDNSOutageCount = 0
    /// Outages the EGRESS-DEAD cause declared — a full-tunnel chain whose link answers but whose
    /// upstream forwarded nothing while the user sustainedly asked. A subset of ``outageCount``,
    /// and the counterpart of ``tunnelDNSOutageCount`` for the third arm.
    ///
    /// Its whole reason to exist is attribution: an egress-dead outage surrenders with the generic
    /// ``ChainedReconnectPolicy/Surrender/budgetExhausted`` reason (the arm declares an outage, the
    /// blackhole budget then runs out), so the surrender log alone cannot say WHICH arm fired.
    /// Read this against ``tunnelDNSOutageCount``: an ``outageCount`` step with THIS advancing and
    /// tunnelDNS flat, on a session whose `rxBytes` keep climbing (keepalives) and
    /// `forwardedNonDNSByteCount` flat, is the egress-dead signature — the one a link-silence or
    /// DNS-arm outage does not produce. Bounded per lifecycle like the cause itself
    /// (``ChainedOutageDriver/maximumEgressDeadOutagesPerLifecycle``).
    public var egressDeadOutageCount = 0
    /// Unanswered observations DROPPED because the window they were stamped in had already
    /// been retired (S6) — a roam, a wake, or a recovery overtaking an in-flight report.
    ///
    /// Distinct from an observation that was merely cleared afterwards, which is invisible in
    /// ``tunnelDNSUnansweredObservationCount`` because that tally increments before the gate.
    /// Anything but a trickle here means reports are outliving their windows routinely, and
    /// the failures the declaration predicate is supposed to see are being discarded.
    public var tunnelDNSStaleObservationCount = 0
    /// Times the tunnel-DNS observation window was retired (S6) — a wake, a roam, EVERY served
    /// answer, and an outage ending through `endOutage()`.
    ///
    /// Both halves of that list are narrower than they look, so they are spelled out: a served
    /// answer retires whether or not an outage is open, because both arms of the answered
    /// handler retire; and an outage ending does NOT always retire, because the offline end
    /// site ends one without going through `endOutage()` at all. Nothing accumulates while
    /// offline (`isQuiesced` gates the arming path), and the roam back retires, so that site
    /// needs no retirement of its own.
    ///
    /// One per logical retirement is the invariant, not merely a statistic: each retirement
    /// invalidates every report already in flight, so a path that retires twice for one event
    /// discards observations stamped in a window that was legitimately open. Read against
    /// ``tunnelDNSStaleObservationCount`` to tell "the resolver is quiet" from "its evidence
    /// keeps being thrown away".
    public var tunnelDNSWindowRetirementCount = 0

    /// The self-heal fired: an unpaired `sleep()` was force-resumed by proof-of-life (the Focus
    /// poll or an inbound packet running while `isSuspended` was still set) rather than by an
    /// iOS `wake()`. Read against a `sleep` log with no paired `wake`: a non-zero count is the
    /// stuck-dark-tunnel this recovers (field 2026-08-24 — see the reliability incident memory).
    public var selfHealResumeCount = 0

    // Data-path pressure tallies, surfaced for the brief-stall investigation (2026-08-24): a
    // sub-60 s forwarding stall left every counter on the liveness line flat, and these four
    // were being tallied by the runner's queue and gauges but surfaced nowhere. They live on
    // the RUNNER and reset with its session, so the driver folds a retiring runner's totals in
    // (`absorbRunnerTallies`) and `snapshotCounters()` overlays the live runner's — the
    // surfaced value is monotonic across rebuilds, which is what makes a 60 s delta honest.

    /// Packets reaching this live driver's read-loop boundary; DNS and later drops are included.
    public var outboundInputPacketCount = 0
    /// Input packets received while the live driver had no runner to accept them.
    public var outboundWithoutRunnerPacketCount = 0
    /// Packets passed to the filtered DNS handler across live and retired runners.
    public var dnsHandledPacketCount = 0
    /// Outbound malformed packets discarded across live and retired runners.
    public var malformedPacketCount = 0
    /// Outbound DNS packets the classifier could not safely filter.
    public var unfilterableDNSPacketCount = 0
    /// Directly identified port-853 policy drops across live and retired runners.
    /// Disjoint from generic DNS drops; unattributed fragment continuations remain generic.
    public var unfilterableEncryptedDNSPacketCount = 0
    /// Outbound IPv6 packets discarded across live and retired runners.
    public var droppedIPv6Count = 0
    /// Actual packet calls into the engine, not a delivery or forwarding claim.
    public var encapsulationAttemptCount = 0

    /// Outbound packets the bounded queue evicted or refused under pressure.
    public var shedPacketCount = 0
    /// Outbound packets in batches refused at the dispatch boundary (backlog at ceiling).
    public var refusedOutboundBacklogPacketCount = 0
    /// Inbound datagrams refused at the dispatch boundary (backlog at ceiling).
    public var refusedInboundBacklogDatagramCount = 0
    /// Send completions the transport answered with an error, current channel only.
    public var sendCompletionErrorCount = 0
    /// Datagrams the engine produced for the peer, across retired sessions and the live one.
    ///
    /// Read against ``ChainedRunnerCounters/sendToPeerCount``'s doc: flat at zero on a session
    /// with no handshake means the engine emitted nothing, which is a different fault from a
    /// peer that is not answering — and the two are indistinguishable without it.
    public var sendToPeerCount = 0

    /// Liveness samples (the 500 ms established tick) that found the send channel pinned at its
    /// in-flight bound. A LEVEL sampled at tick cadence, so its delta measures DURATION where
    /// the park/shed tallies measure volume: a 60 s window with `saturatedTickCount` up by 4 had
    /// the transport wedged for roughly two seconds — the back-pressure signature of a brief
    /// stall, distinguishable from an ordinary burst that saturates between two ticks and drains.
    /// pinned: ChainedOutageDriverTests.testASaturatedSampleIsCountedSoWedgeDurationIsLegible
    public var saturatedTickCount = 0

    /// Whether the driver is currently suspended (its engine tick disarmed). Stamped at snapshot
    /// time. `true` on a liveness line means the tunnel is dark: nothing pumps the engine and no
    /// outage detector runs until a paired `wake()` OR the self-heal resumes it.
    public var isSuspended = false

    /// In-tunnel destinations currently under sustained demand with nothing coming back, and the
    /// longest such wait in seconds. Stamped live from the runner, like ``isSuspended`` and unlike
    /// the pressure tallies above — a retired session's unanswered host is not a fact about the
    /// live one, so these are ASSIGNED and never accumulated.
    ///
    /// REPORT ONLY. Nothing here feeds `ChainedEstablishmentPolicy`, declares an outage, or
    /// surrenders, and unlike ``egressDeadOutageCount`` they are populated under BOTH routing
    /// policies. That asymmetry is the entire point of the slice: PR #567 confined the egress-dead
    /// DECLARATION to `.fullTunnel` because a flat aggregate is not proof of dead egress while the
    /// runner still carries the configured AllowedIPs traffic, which left split tunnel with no
    /// forwarding-health signal at all. A per-destination reading is not an aggregate, and a
    /// read-only one is not a gate, so neither of that confinement's reasons reaches it.
    /// pinned: ChainedOutageDriverTests.testASplitTunnelStillReportsAnUnansweredDestination
    /// pinned: ChainedOutageDriverTests.testASplitTunnelNeverDeclaresAnEgressDeadOutage
    public var unansweredDestinationCount = 0
    /// The longest current unanswered wait in seconds, or zero when none. A duration, never an
    /// address: this reaches a bug report, and a tailnet address names the user's network as
    /// surely as a resolver address does (`redactingChainedFallbackAddresses`, PR #575, PR #592).
    public var longestUnansweredDestinationSeconds = 0

    public init() {}
}

/// Drives one chained tunnel's health: it decides when the tunnel is in an outage, spends the
/// blackhole budget on attempts to fix it, and surrenders when the budget is gone.
///
/// ## `INV-CHAIN-3` — armed whenever the device is awake
///
/// From `beginOutage` until either the outage ends, a surrender is reported, **the device
/// suspends, or the tunnel retires the driver**, **at least one deadline timer is armed, and no
/// armed instant is later than `outageStart + maximumBlackholeSeconds` on the same clock that
/// produced `outageStart`.** After a surrender: nothing is armed, the tick is cancelled, and the
/// sink has been called exactly once. After a retirement (``retire()``): nothing is armed, the
/// tick is cancelled, the runner is released, and the sink is never called again.
///
/// SUSPENSION IS AN EXEMPTION, stated here because this doc is where a reader checks the rule
/// before changing the timers. ``sleep()`` quiesces the deadline, the retry delay and the live
/// watchdog while leaving the outage open, so between a sleep and its paired wake this driver
/// is timing an outage with nothing armed. That is deliberate: the process is suspended, so
/// nothing is being blackholed, and a one-shot delivered across the boundary could only
/// surrender — which a paired wake cannot undo. The wake closes it by ending the outage or, if
/// no runner survived, beginning a fresh one with a fresh deadline. See `docs/invariants.md`,
/// which states the same exemption.
///
/// Phrased over observables rather than over an enum. "Exactly one of three states" would be
/// enforced by the compiler and would assert nothing.
/// pinned: ChainedOutageDriverTests.testSomethingIsAlwaysArmedInsideTheBudgetAndNothingBeyondIt
/// pinned: ChainedOutageDriverTests.testTheSuspensionExemptionIsBoundedByTheWakeThatFollowsIt
///
/// ## Why this is not part of `ChainedSessionRunner`
///
/// The runner owns one `WireGuardSession` for its lifetime and its initialiser can fail. The
/// budget must OUTLIVE sessions — `ChainedReconnectPolicy` says measuring from the session
/// boundary "would restart the budget on every attempt and it would never expire" — and it must
/// also bound the time spent FAILING to build one, which is inside the outage window. So one
/// driver per tunnel lifecycle, a fresh runner per attempt.
///
/// ## Queue
///
/// One serial engine queue, shared with every runner it builds, never `dnsStateQueue`
/// (`INV-QUEUE-1`). All four timer families fire on it. Every supervisor mutation, every engine
/// call, the authorize-and-arm step and its mirror run inline on it with no hop.
public final class ChainedOutageDriver: @unchecked Sendable {
    /// How long an UNANSWERED obliging send may stand before this is called an outage.
    ///
    /// ## What this predicate does and does not claim
    ///
    /// It detects that the WIREGUARD LINK is not working: we sent the peer something it is
    /// protocol-obliged to answer, and nothing authenticated came back. That evidence is
    /// unforgeable — producing it requires the peer's key — so no remote party can manufacture
    /// an outage THROUGH THIS ARM.
    ///
    /// The tunnel-DNS arm (S6) is the one that is not unforgeable, and it says so where it
    /// lives: a resolution outcome is evidence about chosen traffic, so a domain an attacker
    /// controls can produce it on demand. That arm carries its own bound
    /// (``maximumTunnelDNSOutagesPerLifecycle``) rather than borrowing this one's; this
    /// sentence used to claim unforgeability for the driver as a whole, and adding a second
    /// cause is what made the difference load-bearing.
    ///
    /// This LINK-SILENCE arm deliberately does not try to detect a peer whose link is healthy but
    /// whose EGRESS is dead: it keys on the unforgeable authenticated datagram, and a peer whose
    /// upstream forwards nothing still answers every one. That fault is a SEPARATE cause
    /// (``egressDeadThresholdSeconds``), on a signal this arm cannot use. The two worlds are
    /// byte-identical in the LIVENESS SAMPLE — outbound packets leave, authenticated datagrams
    /// arrive, nothing is delivered — but they are NOT identical in `forwardedNonDNSByteCount`
    /// (PR #558): that counter is a delivered-scope fact, bytes the peer actually carried from the
    /// internet, and it needs no probe target of its own — the assumption the earlier version of
    /// this note was written under, and which stopped holding when the connect gate added it.
    ///
    /// The predicate that once tried this from the link arm was a different thing: it keyed on
    /// data silence plus outbound demand, so one destination silently dropping SYNs satisfied it
    /// in five seconds and any web page could tear the session down; and its only remediation was
    /// tear-down-and-rebuild, which does nothing for a peer whose forwarding is broken. The
    /// egress-dead cause avoids both: it measures the delivered-scope counter over a full
    /// threshold, gates on the user's own general (non-DNS) traffic, bounds itself per lifetime,
    /// and SURRENDERS to DNS-only rather than rebuilding — a broken upstream is not fixed by a
    /// rebuild, but the user is served by falling back to the physical path with DNS still
    /// filtered. (``DataPathHealth`` surfaces the same fault read-only and refuses to RECONNECT on
    /// it, #548; surrender is a different remediation, not a reconnect.)
    ///
    /// ## The derivation
    ///
    /// A data send obliges a keepalive at `KEEPALIVE_TIMEOUT` (10 s). The engine treats that same
    /// condition as grounds for a fresh handshake at `KEEPALIVE_TIMEOUT + REKEY_TIMEOUT` (15 s),
    /// and declaring earlier pre-empts the recovery it is already about to attempt. That
    /// handshake must survive one lost datagram, so add one `REKEY_TIMEOUT` (5 s) — the same
    /// allowance `minimumUsefulAttemptSeconds` is derived from. Floor: 20 s of true elapsed time.
    /// The clock floors, so `>= 21` is first true at 20.001 s; the extra second is arithmetic,
    /// not judgement. The ceiling is `REKEY_ATTEMPT_TIME` (90 s), where the engine reports
    /// `connectionExpired` itself and a clock starts anyway.
    /// pinned: ChainedOutageDriverTests.testTheLinkSilenceThresholdSitsBetweenTheEnginesOwnTimers
    public static let linkSilenceThresholdSeconds = 21

    /// How long tunnel-DNS resolutions must go unanswered — across at least two distinct
    /// names — before the cause declares an outage (S6).
    ///
    /// The same figure as ``linkSilenceThresholdSeconds``, by derivation rather than
    /// coincidence: the resolver's answers ride the same link the silence threshold was
    /// derived for, so an engine-side recovery the link arm deliberately waits out (a fresh
    /// handshake at 15 s, plus one lost-datagram allowance) can also be what un-wedges the
    /// resolver path — declaring earlier pre-empts it identically. The window spans many
    /// resolution attempts (the transport's per-attempt budget is single-digit seconds), so
    /// a declaration is never one query's bad luck.
    public static let tunnelDNSUnservedThresholdSeconds = 21

    /// How many outages the tunnel-DNS cause may declare in one driver lifetime.
    ///
    /// THE BOUND THAT MAKES AN UNFORGEABLE-EVIDENCE ARM'S NEIGHBOUR SAFE. Unlike link
    /// silence, this cause's evidence is about CHOSEN TRAFFIC: a domain an attacker
    /// controls answers nothing on demand, and its subdomains supply unlimited distinct
    /// name keys, so the two-name floor is an accident defence and not an adversary one.
    /// Each declaration tears the session down and rebuilds it — a data-path blackhole for
    /// ALL traffic, not just DNS — so an unbounded cause hands a chosen-traffic attacker a
    /// repeating blackhole for as long as the user stays on their page.
    ///
    /// A cap rather than a cooldown, because the two answer different questions and only
    /// this one is bounded over a lifetime: a cooldown still permits an unbounded number of
    /// rebuilds at its own rate. And the escalation this cause exists for is a resolver
    /// that STAYS dead — which the budget resolves in one outage, by surrendering. A second
    /// and third declaration are the honest allowance for "the rebuild fixed it, and it
    /// broke again"; past that, repeated recovery is evidence the resolver is flapping
    /// rather than dead, and rebuilding a working session does not fix a flapping resolver.
    /// Once spent, chained mode keeps running and DNS keeps failing closed per `INV-DNS-1`
    /// — the conservative direction, the same one every other guard here leans.
    /// pinned: ChainedOutageDriverTests.testTheTunnelDNSCauseIsBoundedPerLifecycle
    public static let maximumTunnelDNSOutagesPerLifecycle = 3

    /// How long a chain must FORWARD no general (non-DNS) traffic — while the user is asking for
    /// some — before the egress-dead cause declares an outage.
    ///
    /// The fault this catches is a chain whose WireGuard LINK stays healthy (keepalives and
    /// handshakes answered) but whose upstream has stopped forwarding to the internet: the
    /// connect gate (``ChainedEstablishmentPolicy``) rejects it at establishment, but a server
    /// that forwarded at connect and then lost its own upstream sails past that and leaves the
    /// user "Protected" over a dead path. The link-silence arm cannot see it — the peer answers
    /// every obliging send at the transport layer — and the tunnel-DNS arm stays quiet because a
    /// SERVFAIL counts as an answer.
    ///
    /// The signal is `forwardedNonDNSByteCount` (PR #558): bytes the peer actually delivered from
    /// the internet that cleared AllowedIPs and are not a DNS reply from the resolver (source
    /// address AND port 53, `ChainedInboundDNSReply`). It is a DELIVERED-SCOPE fact
    /// that needs no probe — the exact signal the ``linkSilenceThresholdSeconds`` note once said
    /// this layer did not have. The same figure as the other two thresholds, and by the same
    /// derivation: a chain that just lost forwarding may still recover on the engine's own
    /// handshake at 15 s plus one lost-datagram allowance, so declaring earlier pre-empts a
    /// recovery already in flight.
    public static let egressDeadThresholdSeconds = 21

    /// How long the user may go without asking for general traffic before the egress-dead demand
    /// window LAPSES — the guard that keeps a one-shot packet, or a sparsely-touched healthy chain,
    /// from ever reaching the threshold.
    ///
    /// Well under ``egressDeadThresholdSeconds`` so a lapse always resets the window before it could
    /// declare, and comfortably above a stalled connection's within-window retransmit backoff (a
    /// dead chain the user is actively loading retransmits SYNs at ~1/2/4/8 s, so its largest gap
    /// inside the window is ~8 s): sustained demand keeps the window alive, a pause of this length
    /// lapses it. Erring short is the safe direction — a dead chain the user only touches sparsely
    /// is left alone (chained mode keeps running, the conservative outcome) rather than a healthy
    /// idle chain being surrendered.
    public static let egressDeadDemandContinuitySeconds = 10

    /// How many outages the egress-dead cause may declare in one driver lifetime.
    ///
    /// Bounded for the same reason as ``maximumTunnelDNSOutagesPerLifecycle``: this cause keys on
    /// CHOSEN traffic, not the unforgeable link evidence the silence arm rests on. A user talking
    /// only to an unresponsive destination produces obliging non-DNS sends that never forward a
    /// byte back, so an unbounded cause would hand a single dead endpoint a repeating surrender.
    /// Three is the honest allowance for "the surrender's fresh DNS-only session let the user
    /// reach a working path, they re-enabled, and it broke again"; past that, chained mode keeps
    /// running and forwarding keeps failing — the conservative direction every guard here leans.
    /// pinned: ChainedOutageDriverTests.testTheEgressDeadCauseIsBoundedPerLifecycle
    public static let maximumEgressDeadOutagesPerLifecycle = 3

    /// How long a rebind has to prove itself before the driver falls back to a full rebuild.
    ///
    /// Well under ``linkSilenceThresholdSeconds`` — a confirmation window longer than the
    /// detector it replaces would buy nothing — and a small fraction of
    /// `maximumBlackholeSeconds`, so a rebind that fails still leaves most of the budget for the
    /// ladder that follows it. The whole point of the fast path is that its worst case is the
    /// old behaviour plus this, not instead of it.
    /// pinned: ChainedOutageDriverTests.testAnUnconfirmedRebindFallsBackToAFullRebuild
    public static let rebindConfirmationSeconds = 3

    /// The re-anchor RETRY's confirmation window — LONGER than the first ``rebindConfirmationSeconds``
    /// by derivation, not slack. The retry re-anchors with a forced handshake; if that initiation is
    /// itself lost, the engine retransmits it only at `REKEY_TIMEOUT` (5 s — boringtun
    /// `ThirdParty/wireguard-core/boringtun/src/noise/timers.rs`). A 3-second window would expire
    /// before that retransmit, leaving the "engine-retransmitted" re-anchor a single datagram like
    /// the keepalive it replaces (Codex, PR #574). So the window is one `REKEY_TIMEOUT` plus a
    /// round-trip-and-tick margin — the same lost-datagram allowance the silence thresholds add — so
    /// a lost initiation's retransmit lands and confirms rather than falling to the rebuild. Still
    /// well under ``linkSilenceThresholdSeconds``, so a dead path the retry cannot save stays
    /// bounded, one window later.
    /// pinned: ChainedOutageDriverTests.testAReanchorRetryThatConfirmsAvoidsTheRebuild
    public static let rebindReanchorRetrySeconds = 7

    /// The shortest interval between two path-triggered SOCKET recoveries (C5).
    ///
    /// Equal to ``rebindConfirmationSeconds`` by DERIVATION, not coincidence: a socket
    /// replaced faster than its own confirmation window can close is superseded before it can
    /// prove anything, so a flap burst was building one source port per callback and closing
    /// each before the peer's replies could reach it — with the outage supervisor seeing none
    /// of it, because no session ends. One recovery LEADS the burst immediately (a single
    /// handoff keeps R2's whole point: act now, not 21 seconds late) and one trailing recovery
    /// runs when the window ends, so the burst's FINAL path always gets its socket. In
    /// between, transitions are still observed — counters and silence-clock resets run per
    /// transition — but build nothing.
    ///
    /// Well under ``linkSilenceThresholdSeconds`` for the same reason the confirmation window
    /// is: a settle delay that approaches the silence detector would open the very blackhole
    /// it exists to shorten.
    /// pinned: ChainedOutageDriverTests.testAFlapBurstBuildsOneSocketNowAndOneAtTheWindowEnd
    public static let pathRecoverySettleSeconds = rebindConfirmationSeconds

    /// The engine pump's cadence while a session exists.
    ///
    /// Two rates, and the fast one is bounded by construction: it runs only while an outage is
    /// being timed, and the supervisor bounds an outage at `maximumBlackholeSeconds`.
    static let outageTickInterval = DispatchTimeInterval.milliseconds(250)
    static let outageTickLeeway = DispatchTimeInterval.milliseconds(25)
    /// 500 ms rather than a second, and the usual justification for that is backwards.
    ///
    /// The engine's rate limiter resets its counter from inside the tick, self-gated on a full
    /// second having passed. Dispatch leeway DEFERS a fire and never advances it — so "early
    /// delivery" is not the mechanism. The real one: at a one-second interval a single deferred
    /// fire lands late, resets, and the next on-schedule fire is then less than a second after
    /// it, so it no-ops and the effective reset window becomes two seconds — halving the
    /// handshake rate limit, which is the denial-of-service weakening the engine wrapper
    /// documents. At 500 ms the typical window is exactly one second and the worst case is
    /// bounded well under two.
    /// pinned: ChainedOutageDriverTests.testTheTickCadenceClearsTheRateLimiterFloor
    static let establishedTickInterval = DispatchTimeInterval.milliseconds(500)
    static let establishedTickLeeway = DispatchTimeInterval.milliseconds(50)
    /// A failed lifecycle-proof write retries independently of the liveness tick. One second is
    /// short enough to precede ordinary suspension/termination while bounding Keychain attempts
    /// at one in flight plus one scheduled retry per second during longer unavailability.
    static let healthyForwardingProofRetrySeconds = 1

    private let engineQueue: ChainedEngineQueue
    private let clock: ChainedMonotonicClock
    private let timers: ChainedTimerScheduling
    private let source: ChainedSessionSource
    private let surrender: @Sendable (ChainedReconnectPolicy.Surrender, ChainedDriverCounters) -> Void
    /// First delivered inbound packet for this provider lifecycle. Called on the engine queue;
    /// consumers must hop off before doing persistence or other blocking work, then complete with
    /// whether the proof became durable so a transient failure remains retryable.
    private let onHealthyForwarding:
        (@Sendable (@escaping @Sendable (Bool) -> Void) -> Void)?
    private let onRunnerChanged: (@Sendable () -> Void)?
    private var hasObservedHealthyForwarding = false
    private var healthyForwardingReportIsInFlight = false
    private var didReportHealthyForwarding = false
    private var healthyForwardingRetry: ChainedArmedTimer?

    /// The tunnel's routing shape, carried so the EGRESS-DEAD cause can be confined to full
    /// tunnels. In a split tunnel the runner still carries the configured `AllowedIPs` traffic, so
    /// `sawObligingNonDNSSend` fires on split user sends exactly as it does full-tunnel — but "no
    /// byte forwarded" is NOT a fault there: a send to a cached or literal `AllowedIPs` address that
    /// happens to be unresponsive leaves the forwarding counter flat on a perfectly healthy chain,
    /// and no unrelated DNS reply is guaranteed to land inside the window to reset it. Only in full
    /// tunnel does "the user is asking for general traffic and NOTHING is delivered" unambiguously
    /// mean the upstream's egress is dead (Codex, PR #567). None of the other causes are
    /// routing-dependent, so nothing else reads this.
    private let routingPolicy: ChainedRoutingPolicy

    /// The ONLY `ChainedOutageSupervisor` anything holds, authorized from exactly one call site.
    ///
    /// NOT ENFORCED, and worth saying rather than implying. `authorizeAttemptStartingNow` is
    /// `public` on a `public` value type, so "the driver is its only caller" is a convention at
    /// module scope, not a compiler property. What IS structural is narrower and is the part C1
    /// actually needs: this instance is private, and the value recording a live attempt requires
    /// its watchdog non-optionally, so an authorization nothing is bounding cannot be
    /// represented HERE.
    private var supervisor = ChainedOutageSupervisor()

    /// An attempt that has been authorized AND armed. The watchdog is non-optional, so the two
    /// cannot come apart; see ``ChainedArmedTimer``.
    private struct LiveAttempt {
        let attempt: Int
        let deadlineAtSeconds: Int
        let receipt: ChainedAttemptReceipt
        let watchdog: ChainedArmedTimer
    }
    private var live: LiveAttempt?
    private var outageDeadline: ChainedArmedTimer?
    private var retryDelay: ChainedArmedTimer?
    private var generation: ChainedOutageGeneration?
    private var pendingTicket: ChainedAttemptTicket?
    /// The live runner.
    ///
    /// `didSet` RATHER THAN SIX CALL SITES, and that is the point of the observer. This property
    /// is assigned in six places — adopt, rebuild, and four retirement paths — and the health
    /// identity that has to follow it must not depend on every one of them remembering. A
    /// notification on the property itself cannot be forgotten by a path added later, which is
    /// the failure mode this PR kept reproducing (Codex P2, PR #613).
    ///
    /// Fires on the ENGINE queue, so the observer must not block: the provider's hops to
    /// `dnsStateQueue` asynchronously, per `INV-QUEUE-1`. Idempotent by design — a redundant
    /// assignment costs one no-op mirror pass, and the mirror persists only when a value moved.
    private var runner: ChainedSessionDriving? {
        didSet { onRunnerChanged?() }
    }
    private var nextSerial: UInt64 = 0
    private var hasSurrendered = false
    /// Set at the sleep boundary, cleared by the wake. See ``sleep()``.
    private var isSuspended = false
    /// A surviving keypair does not verify the network after a paired suspension. This latch
    /// affects setup presentation only; fresh authenticated peer evidence clears it on a normal
    /// liveness tick. Wake/path drains must never turn discarded credit into readiness.
    private var setupRequiresPostWakePeerEvidence = false
    /// Presentation evidence only. Forwarding/recovery counters and timing are unchanged.
    private var verificationEpoch: UInt64 = 1
    private var verificationForwardingBaseline: (session: UInt64, transport: UInt64, bytes: UInt64)?
    /// A live-but-unsampleable runner cannot borrow a zero wake baseline. Replacement or a later
    /// genuine wake with a readable boundary can clear this fence; ordinary reads cannot.
    private var unavailableWakeBaselineSession: UInt64?
    /// The monitored path is unsatisfied — there is no network at all.
    ///
    /// SEPARATE from ``isSuspended`` rather than folded into it, because the two are latched by
    /// different callers and OVERLAP: a device can sleep while offline and wake while still
    /// offline. One shared flag would have `wake()` clear a latch the path monitor owns, and the
    /// driver would resume spending the budget on a network that is still not there.
    private var isOffline = false
    /// The tunnel tore this driver down. Terminal — nothing clears it. See ``retire()``.
    private var isRetired = false
    /// None of the three decides anything. `INV-CHAIN-3`'s armed-budget rule is exempt for
    /// exactly these windows — nothing is being blackholed while the user has no network or is
    /// not present, and a retired driver's tunnel no longer claims the routes an outage would
    /// blackhole.
    private var isQuiesced: Bool { isSuspended || isOffline || isRetired }
    /// A satisfied path transition that arrived while suspended, waiting for the paired wake.
    private var pendingPathRecovery = false
    /// A coalesced SOCKET recovery that is owed but has no armed timer: interrupted by
    /// `sleep()` (consumed by the paired wake), or deferred past an outage the settle
    /// window overlaps (satisfied by the ladder's next fresh build, or consumed by
    /// `endOutage` when evidence keeps the runner instead).
    ///
    /// A distinct latch from ``pendingPathRecovery``, because the two defer different
    /// amounts: that one defers a TRANSITION — its wake re-runs `recoverAfterPathChange`,
    /// counters included, which is right for a transition nothing has counted yet — while
    /// this one defers only the socket half of transitions that were already observed.
    /// Routing it through the transition latch inflated `pathRecoveryCount` (and, across a
    /// short sleep, `coalescedPathRecoveryCount`) with transitions that never occurred,
    /// which corrupts the exact outage-vs-flap diagnostic the pair exists for
    /// (Codex, PR #504).
    private var pendingSettledRecovery = false
    /// Armed when a rebind swapped the transport, cleared by authenticated evidence on the new
    /// one. On fire, a LONE rebind spends one bounded re-anchor retry (a forced handshake + a
    /// fresh window) before any rebuild; a second miss, or a rebind caught in a flap burst, falls
    /// back to a full rebuild — R1, at most two windows late.
    private var rebindConfirmation: ChainedArmedTimer?
    /// Whether the CURRENT rebind's confirmation has already spent its one re-anchor retry. Reset
    /// the instant a fresh rebind arms confirmation (``attemptRebind``), so each rebind gets
    /// exactly one retry — a single lost re-anchor keepalive on a working new path no longer costs
    /// a full rebuild, while a genuinely dead path still rebuilds one window later.
    private var rebindReanchorRetried = false
    /// When the socket half of a path recovery last RAN, so a flap burst cannot run it 1:1
    /// with callbacks (C5). Nil until the first recovery.
    private var lastPathSocketRecoveryAtSeconds: Int?
    /// Armed while a coalesced burst waits for its settle window to end; the fire runs the one
    /// trailing recovery the burst gets. Same slot discipline as every other one-shot here:
    /// cancelled AND cleared at each teardown, so a stale serial cannot act.
    private var settledPathRecovery: ChainedArmedTimer?

    /// Kept for diagnostics only. It is NOT part of the predicate — see the type's note.
    private var lastInboundDataAtSeconds: Int
    /// When we last sent something the peer owes an answer to, with none received since.
    ///
    /// MEASURED FROM THE SEND, not from the last answer, and that is the structural fix for the
    /// defect the previous predicate had: `now - lastInboundData >= threshold` is ALREADY true on
    /// a device that has been quiet for hours, so the whole window was consumed before the fault
    /// occurred and a single packet was enough to declare. This is nil on an idle tunnel and can
    /// only be armed by an act of our own.
    private var firstUnansweredSendAtSeconds: Int?
    /// When the transport went to its send bound and stayed there.
    ///
    /// The one state the send-based predicate cannot see: a saturated transport parks every
    /// outbound packet, so no obliging send is ever issued and `firstUnansweredSendAtSeconds`
    /// never arms — a wedged socket would blackhole with no clock running at all.
    /// pinned: ChainedOutageDriverTests.testAWedgedTransportDeclaresAnOutageWithoutASingleObligingSend
    private var channelSaturatedSinceSeconds: Int?
    /// When the first unanswered tunnel-DNS resolution of the current accumulation arrived,
    /// with no served answer since (S6).
    ///
    /// The one fault the link causes above cannot see, and the scope the plan's S6 names: a
    /// peer whose link is healthy — keepalives answered, data flowing — but whose resolver is
    /// dead. Armed and fed by the provider's observations, never by the sample channel: the
    /// sample is read-and-clear with drain sites that deliberately DISCARD stale credit, which
    /// is the wrong lifetime for failure evidence, and the tick that pulls it stops during
    /// retry delays.
    private var firstUnansweredTunnelDNSAtSeconds: Int?
    /// Distinct query names (opaque keys) seen failing in the current accumulation.
    ///
    /// The declaration requires at least two, and that floor is the founder's trap defence
    /// (resolved decision 3): one fragmenting or OPT-ignoring domain, retried by a browser,
    /// produces a continuous single-name failure stream — resolver-wide evidence it is not,
    /// and spending the outage budget on it would surrender chaining feature-wide over one
    /// domain.
    ///
    /// STOPS GROWING AT THE DECISION THRESHOLD. Two is the only count that decides anything,
    /// so admitting a third key buys nothing and costs residency inside `INV-MEM-1` — and a
    /// failing resolver under an ordinary browser produces new names as fast as a page has
    /// subresources, with a chosen-traffic attacker producing them without limit. A set that
    /// only ever holds what it decides on cannot become a memory surface.
    private var unansweredTunnelDNSNameKeys: Set<UInt64> = []
    /// Outages this cause has declared in this driver's lifetime, against
    /// ``maximumTunnelDNSOutagesPerLifecycle``.
    private var tunnelDNSDeclarationCount = 0
    /// Serializes an observation's timestamp with its submission — see
    /// ``reportTunnelDNSObservation(_:)``. NOT engine-queue state: it is held only by
    /// producers, on their own threads, and never while anything blocks.
    private let observationSubmission = NSLock()
    /// Which accumulation window an observation belongs to, guarded by
    /// ``observationSubmission``.
    ///
    /// The lock alone orders observations against EACH OTHER; it cannot order them against
    /// the resets, because `wake` and `pathChanged` submit their work without taking it. A
    /// producer preempted after stamping therefore lets a path transition clear the window
    /// first, and the pre-transition timeout then seeds the NEW path's window and can
    /// combine with a later failure to declare an outage that never happened
    /// (Codex, PR #513). Bumping this wherever the accumulation is cleared gives every
    /// observation a window to belong to, and the handler drops the ones that outlived
    /// theirs.
    private var observationEpoch: UInt64 = 0
    /// Whether the outage currently being timed was opened by the tunnel-DNS cause (S6).
    ///
    /// The per-cause half of the recovery predicate: link evidence must not end an outage
    /// this cause opened — on a healthy link with a dead resolver every keepalive would end
    /// it, the cause would re-arm a threshold later, and the kill-rebuild cycle would repeat
    /// forever without surrendering: unbounded fail-closed, the outcome the shared budget
    /// exists to bound (C4's "a stale observation never clears a live one", where the stale
    /// observation is the link's). Its disarming observation is a served answer, per C4's
    /// "every producer defines the observation that disarms it". Survives path transitions
    /// while the outage is open — a roam does not make a dead resolver less dead — and
    /// clears with the outage, on a served answer, or on a paired wake's refund.
    private var outageHeldByTunnelDNS = false
    /// When the user's current run of unanswered general (non-DNS) demand began — with no byte
    /// forwarded and no lapse in the asking since. `nil` when the user is not currently asking.
    ///
    /// The egress-dead clock measures from HERE, from DEMAND ONSET, exactly like the silence arm's
    /// ``firstUnansweredSendAtSeconds`` — NOT from the last forwarding. Anchoring at the last
    /// delivered byte was wrong: it let idle time BEFORE the user asked be counted toward the
    /// threshold, so a chain that forwarded, sat idle for the threshold, then saw one packet would
    /// surrender a healthy tunnel. Measuring from onset means only time the user is actually asking
    /// counts.
    private var firstUnansweredNonDNSSendAtSeconds: Int?
    /// When the user last asked for general (non-DNS) traffic, so the demand can be told from a
    /// one-shot packet.
    ///
    /// SUSTAINED demand is the requirement, not a single arm. If no obliging non-DNS send arrives
    /// for ``egressDeadDemandContinuitySeconds``, the window LAPSES (both this and
    /// ``firstUnansweredNonDNSSendAtSeconds`` reset): a user who sends one packet and goes idle, or
    /// touches the chain sparsely, is not "actively blocked", and an idle chain that forwards
    /// nothing is not a fault. Only a chain the user keeps asking of — retransmits, retries, new
    /// requests — while nothing is forwarded can reach the threshold. That does not resurrect the
    /// removed predicate's flaw (a single SYN-dropped page tearing the session down in 5 s): a page
    /// among ordinary browsing forwards SOME byte and resets the window, and a user talking only to
    /// an unresponsive destination — the one shape that could still sustain the window — is capped
    /// by ``maximumEgressDeadOutagesPerLifecycle``.
    private var lastObligingNonDNSSendAtSeconds: Int?
    /// The last `forwardedNonDNSByteCount` sampled, with the session generation it belonged to, so
    /// a climb can be told from the counter's per-rebind reset and from a fresh session's zero.
    private var lastForwardedNonDNSByteCount: UInt64 = 0
    private var lastForwardedGeneration: UInt64 = 0
    /// Outages the egress-dead cause has declared this lifetime, against
    /// ``maximumEgressDeadOutagesPerLifecycle``.
    private var egressDeadDeclarationCount = 0
    /// Whether the outage currently being timed was opened by the egress-dead cause.
    ///
    /// The per-cause recovery half, exactly like ``outageHeldByTunnelDNS``: link evidence must
    /// NOT end an outage this cause opened, because a healthy link is the deceptive part — every
    /// keepalive would end it, the cause would re-arm a threshold later, and the kill-rebuild
    /// cycle would repeat forever without surrendering. Its disarming observation is REAL
    /// forwarding resuming (a delivered non-DNS byte), never a mere reconnect. Survives a roam for
    /// the same reason the tunnel-DNS hold does — a dead upstream is dead on either network.
    private var outageHeldByEgressDead = false
    private var counters = ChainedDriverCounters()
    /// Bumped whenever a NEW runner (a new engine session) is adopted or rebuilt, so a data-path
    /// byte sample can be tagged with the session it came from. The engine's byte totals reset with
    /// the session, and differencing across that boundary would report a bogus window (Codex, PR #554).
    private var sessionGeneration: UInt64 = 0
    /// Session ends that arrived while one was already being processed.
    ///
    /// A FIFO carrying the CAUSE, not a boolean. `perform` is reachable from inside two loops
    /// that resume afterwards and from a transport that completes inline, so a re-entrant end is
    /// ordinary. A boolean would lose the cause — and an end with no cause routes to the watchdog
    /// path, which never records the attempt, which wedges the ladder permanently. The fix for
    /// re-entrancy would have reintroduced the defect it was fixing.
    /// pinned: ChainedOutageDriverTests.testAReEntrantSessionEndKeepsItsCause
    /// The receipt of the last attempt this driver retired.
    ///
    /// Kept because the supervisor accepts a RECEIPT-LESS end only when nothing has ever been
    /// authorized — once in its lifetime, not once per outage. The synthesized end that starts a
    /// ladder therefore has to name the session it is about, and after the first outage the only
    /// name that works is the receipt of the attempt whose session is still running.
    /// pinned: ChainedOutageDriverTests.testASecondOutageReachesTheLadderToo
    private var lastRetiredReceipt: ChainedAttemptReceipt?
    /// Whether a suspension was actually observed, so a wake can be trusted as one.
    /// pinned: ChainedOutageDriverTests.testAWakeWithNoPairedSleepDoesNotRefundTheBudget
    private var sawSleep = false
    /// Whether iOS has actually been told the extension may suspend.
    ///
    /// `isSuspended` is latched by ``sleep()``, but the process keeps RUNNING after that: the
    /// provider drains the event log before signalling the sleep completion, a step its own
    /// comment bounds at roughly four seconds. Packet-flow callbacks still arrive in that window,
    /// and the self-heal read one as proof of a resume — clearing the latch, forcing a handshake
    /// and re-arming the timers immediately before the real suspension. The subsequent wake then
    /// looked unpaired, and the re-armed timers could run and surrender, which is exactly what
    /// quiescing them was for (Codex P1, PR #581).
    private var suspensionBoundaryPassed = false
    private var pendingEnds: [ChainedSessionEndCause] = []
    private var isProcessingEnd = false

    public init(
        engineQueue: ChainedEngineQueue,
        clock: ChainedMonotonicClock,
        timers: ChainedTimerScheduling,
        source: ChainedSessionSource,
        routingPolicy: ChainedRoutingPolicy = .fullTunnel,
        onSurrender: @escaping @Sendable (ChainedReconnectPolicy.Surrender, ChainedDriverCounters) -> Void,
        onHealthyForwarding:
            (@Sendable (@escaping @Sendable (Bool) -> Void) -> Void)? = nil,
        /// Called on the ENGINE queue whenever the live runner is adopted, rebuilt or retired, so
        /// a consumer whose value must follow the runner's lifetime can refresh it promptly
        /// instead of waiting for the next poll. Must not block — hop off the queue.
        onRunnerChanged: (@Sendable () -> Void)? = nil
    ) {
        self.engineQueue = engineQueue
        self.clock = clock
        self.timers = timers
        self.source = source
        self.routingPolicy = routingPolicy
        self.surrender = onSurrender
        self.onHealthyForwarding = onHealthyForwarding
        self.onRunnerChanged = onRunnerChanged
        lastInboundDataAtSeconds = clock.nowSeconds()
    }

    // MARK: - Entry points

    /// The tunnel has a session to drive. Called once, by the wiring that builds the first one.
    public func adopt(_ runner: ChainedSessionDriving) {
        engineQueue.run {
            guard !self.isRetired else { return }
            self.runner = runner
            self.setupRequiresPostWakePeerEvidence = false
            self.verificationForwardingBaseline = nil
            self.unavailableWakeBaselineSession = nil
            self.sessionGeneration &+= 1  // new session: its byte totals start fresh (Codex, PR #554)
            self.rescheduleTick()
        }
    }

    /// Hands a batch to whichever runner is current, and answers whether this driver can
    /// still accept batches at all — `false` once retired.
    ///
    /// The answer exists for the read loop that CAPTURED this driver: provider instances
    /// are reused across starts, so a loop armed by a previous lifecycle can fire once
    /// more after its lifecycle tore down, and a Void signature would have it silently
    /// re-arm and compete with the live lifecycle's loop for every later batch — each
    /// stolen batch dropped whole by a retired driver. `false` lets the stale loop die at
    /// its first post-retirement batch instead. A surrendered-but-not-retired driver
    /// still answers `true`: its lifecycle is alive and the restart is on its way.
    /// pinned: ChainedOutageDriverTests.testARetiredDriverRefusesBatchesSoAStaleLoopCanStop
    @discardableResult
    public func handleOutboundBatch(_ packets: [Data], protocols: [NSNumber]) -> Bool {
        engineQueue.run {
            // A batch reaching this driver is proof the process is executing, so an `isSuspended`
            // still set here is an UNPAIRED sleep — self-heal instantly (the user's first packet
            // after resume) BEFORE forwarding, or the engine queues this packet behind a handshake
            // the disarmed tick will never complete and it blackholes silently (field 2026-08-24).
            self.resumeIfSuspendedOnQueue()
            if !self.isRetired {
                self.counters.outboundInputPacketCount += packets.count
                if self.runner == nil {
                    self.counters.outboundWithoutRunnerPacketCount += packets.count
                }
            }
            self.runner?.handleOutboundBatch(packets, protocols: protocols)
            return !self.isRetired
        }
    }

    /// Admits direct DNS only to the current live runner. No DNS state-queue work occurs here.
    public func sendResolverPacket(_ packet: Data, deadline: MonotonicDeadline) -> Bool {
        engineQueue.run {
            guard !self.isRetired, !deadline.hasExpired() else { return false }
            self.resumeIfSuspendedOnQueue()
            return self.runner?.sendResolverPacket(packet, deadline: deadline) ?? false
        }
    }

    /// The engine pump, and the outage detector.
    /// While `isSuspended`, this decides NOTHING — see ``sleep()``. Cancelling the repeating
    /// timer cannot retract a tick the queue has already been handed, and a tick that runs
    /// after the boundary drives the engine and samples liveness: an engine end then reaches
    /// `finishAttempt`, which arms a fresh deadline and retry — re-arming exactly what the
    /// boundary just quiesced — or surrenders outright for a permanent cause, which a paired
    /// wake can never undo (Codex, PR #483).
    /// pinned: ChainedOutageDriverTests.testATickDeliveredAfterSleepBeganDecidesNothing
    public func tick() {
        engineQueue.run {
            guard !self.hasSurrendered, !self.isQuiesced else { return }
            self.runner?.tick()
            self.sampleLiveness()
        }
    }

    /// The device is suspending.
    public func sleep() {
        engineQueue.run {
            self.sawSleep = true
            self.suspensionBoundaryPassed = false
            self.timers.scheduleTick(every: nil, leeway: .milliseconds(0))
            // THE ONE-SHOTS ARE QUIESCED TOO, not just the repeating tick. A deadline,
            // watchdog or retry delay that is already due — or whose handler is already
            // enqueued — otherwise runs while the device is suspending, and the only thing it
            // can decide there is to surrender. That is unrecoverable rather than merely
            // early: `wake()` returns immediately once `hasSurrendered` is set, so the sleep
            // refund this whole path exists to grant can never undo it (Codex, PR #483).
            //
            // Cancelling here does not leave the budget unbounded, because a paired wake ENDS
            // the outage rather than resuming it — and while the process is suspended there is
            // no user-visible blackhole to bound, which is the same reasoning the refund
            // itself rests on. A wake that finds no runner starts a fresh outage with a fresh
            // deadline, so `INV-CHAIN-3` holds across the boundary rather than through it.
            // CANCELLING IS NOT ENOUGH, and that was the first version of this fix. `cancel()`
            // does not retract a handler the queue has already been handed —
            // ``ChainedArmedTimer`` says so itself — and a cancelled timer whose SLOT is still
            // installed still satisfies its handler's identity guard (`outageDeadline?.serial
            // == serial`). So the slots are cleared, which makes those guards fail on the
            // stale serial, and the live attempt is retired rather than left holding a
            // watchdog that would still match (Codex, PR #483).
            //
            // This is the same teardown a paired wake performs, done eagerly at the boundary
            // instead — which leaves the wake's own branch idempotent rather than duplicated.
            // pinned: ChainedOutageDriverTests.testSleepingQuiescesTheOneShotsSoNoneSurrenders
            // pinned: ChainedOutageDriverTests.testAOneShotAlreadyDeliveredWhenSleepBeganDecidesNothing
            self.outageDeadline?.cancel()
            self.outageDeadline = nil
            self.retryDelay?.cancel()
            self.retryDelay = nil
            // Deliberately keep `healthyForwardingRetry`: it persists evidence already observed
            // before this suspension and must not depend on the repeating tick resuming.
            self.pendingTicket = nil
            self.retireLiveAttempt()
            self.rebindConfirmation?.cancel()
            self.rebindConfirmation = nil
            // A COALESCED RECOVERY SURVIVES THE SUSPENSION AS ITS OWN LATCH. The trailing
            // recovery exists so a burst's FINAL path gets its socket; a sleep landing
            // inside the settle window would otherwise swallow it, and the wake's
            // surviving-runner branch then re-handshakes into the pre-burst socket — a
            // blackhole only the 21 s detector would clean up. Deferred as the SOCKET half
            // only (`pendingSettledRecovery`), not as a transition: the transitions behind
            // it were already counted, and replaying them through `recoverAfterPathChange`
            // at wake inflates the observation counters (Codex, PR #504).
            if self.settledPathRecovery != nil {
                self.pendingSettledRecovery = true
            }
            self.settledPathRecovery?.cancel()
            self.settledPathRecovery = nil
            // The LATCH is what covers the entry points a cleared slot cannot: the repeating
            // tick, and a session end already queued by the runner. Both are handlers the
            // queue may already hold, and both can re-arm timers or surrender if they run.
            self.isSuspended = true
        }
    }

    /// The device has woken, and the budget is REFUNDED if an outage was in progress.
    ///
    /// A deliberate exception to the supervisor's refusal to refund, and it needs to be seen for
    /// what it is. Refunds are forbidden for FLAPPING because a flapping path must not reset a
    /// clock measuring one continuous user-visible outage. A sleep is not a flap: it is a
    /// discontinuity in whether the user is present, nothing an attacker controls suspends this
    /// process, and by definition nothing is being blackholed while it is suspended.
    ///
    /// Without it, sleeping past roughly the midpoint of an outage surrenders on wake without a
    /// single handshake being attempted — the elapsed time is already too large for the policy to
    /// authorize a useful attempt, so the first decision after waking is `.fallBackToDNSOnly`.
    /// A permanent downgrade, on a network the device has not tried yet, for a fault one
    /// handshake would likely clear.
    /// pinned: ChainedOutageDriverTests.testWakingEndsTheOutageAndDiscardsStaleLiveness
    public func wake() {
        engineQueue.run { self.performWake() }
    }

    /// Self-heal for an UNPAIRED `sleep()`. iOS does not guarantee a `wake()` for every `sleep()`,
    /// and an unpaired sleep otherwise latches this driver dark forever: `sleep()` disarms the tick,
    /// and the tick is the single pump for BOTH the engine (keepalive/handshake/sends) AND every
    /// outage detector (`sampleLiveness`), so tx/rx/forwarding go flat and NOTHING trips — only a
    /// cold `startTunnel` recovers (field 2026-08-24, see the reliability incident memory; matches
    /// the standing rule "a quiesce flag is a window, only an epoch survives resume").
    ///
    /// If this runs while `isSuspended` is still set, the process has DEMONSTRABLY resumed without a
    /// `wake()` — a suspended process runs nothing — so we perform the same recovery a paired wake
    /// would. Idempotent: a no-op unless suspended. Called from the provider's Focus poll (a
    /// guaranteed ~60 s backstop) and from `handleOutboundBatch` (instant on the user's first packet
    /// after resume). 🔴 The `isSuspended` guard IS the epoch fence: `sleep()` sets it and only a
    /// resume clears it, and both are serialized on this queue, so a real concurrent sleep either
    /// precedes this (no-op) or follows it (re-quiesces) — it can never be fought mid-flight.
    /// pinned: ChainedOutageDriverTests.testResumeIfSuspendedRecoversAnUnpairedSleep
    /// The provider has finished its pre-suspension work and is about to signal the sleep
    /// completion — from here, execution really does mean the process resumed.
    ///
    /// Serialized behind ``sleep()`` on this queue by construction: the provider issues both from
    /// the same `dnsStateQueue` block, in order.
    /// pinned: ChainedOutageDriverTests.testAPreSuspensionBatchIsNotMistakenForAResume
    public func confirmSuspensionBoundary() {
        engineQueue.run {
            guard self.isSuspended else { return }
            self.suspensionBoundaryPassed = true
        }
    }

    public func resumeIfSuspended() {
        engineQueue.run { self.resumeIfSuspendedOnQueue() }
    }

    /// The engine-queue body of ``resumeIfSuspended()``, so a caller already ON the queue
    /// (``handleOutboundBatch``) can self-heal inline without a re-entrant hop.
    private func resumeIfSuspendedOnQueue() {
        // BOTH conditions. `isSuspended` alone was satisfied during the provider's
        // pre-suspension drain, when the process is still legitimately executing and a packet
        // proves nothing about a resume (Codex P1, PR #581).
        guard isSuspended, suspensionBoundaryPassed else { return }
        counters.selfHealResumeCount += 1
        performWake()
    }

    private func performWake() {
            self.isSuspended = false
            // Cleared WITH the latch it fences, so a later `sleep()` starts from a closed
            // boundary rather than inheriting the previous suspension's open one.
            self.suspensionBoundaryPassed = false
            guard !self.hasSurrendered, !self.isRetired else { return }
            let now = self.clock.nowSeconds()
            // ONLY WITH A PAIRED SLEEP. The provider delivers wakes that were never preceded by
            // a suspension this driver saw, and an unpaired one is not evidence of a
            // user-invisible interval — it is just a callback. Refunding on it would let
            // repeated wakes extend the blackhole past the bound the budget exists to be.
            let observedSuspension = self.sawSleep
            self.sawSleep = false
            // EVERY RESET IS INSIDE THE PAIRING CHECK, including the liveness ones, and they
            // were not. Discarding stale credit is right after a suspension and is a silence
            // clock reset after a mere callback: an unpaired wake pushed detection out by
            // another full threshold, and wakes arriving oftener than that postponed it
            // indefinitely — the same "extend the blackhole at will" the refund rule exists to
            // prevent, through the door beside it.
            // pinned: ChainedOutageDriverTests.testAnUnpairedWakeDoesNotPostponeDetection
            guard observedSuspension else {
                self.rescheduleTick()
                return
            }
            // Credit is discarded on BOTH sides. The runner's sample is a level, so a
            // `sawInboundData` set before the device slept would otherwise certify a peer that
            // has been gone for hours.
            _ = self.takeLivenessSampleReportingForwarding()
            // forceHandshake below retains the old nonexpired keypair. A prompt statistics
            // read must wait for actual post-wake peer evidence, not just that surviving key.
            self.invalidateVerificationEvidenceAfterDrain()
            self.lastInboundDataAtSeconds = now
            self.firstUnansweredSendAtSeconds = nil
            self.channelSaturatedSinceSeconds = nil
            // The tunnel-DNS accumulation is stale for the same reason the silence clock is:
            // evidence gathered before a suspension says nothing about the resolver on the
            // other side of it. The HOLD clears too, because the refund below ends the
            // outage it was holding — fresh post-wake failures re-accumulate from zero.
            self.clearTunnelDNSAccumulationOnQueue()
            self.outageHeldByTunnelDNS = false
            // The egress-dead accumulation is stale for the same reason, and its hold clears too
            // because the refund below ends the outage it was holding.
            self.resetEgressDeadAccumulation()
            self.outageHeldByEgressDead = false
            if self.supervisor.isTimingAnOutage, let generation = self.generation {
                self.supervisor.endOutage(in: generation)
                self.retireLiveAttempt()
                self.outageDeadline?.cancel()
                self.outageDeadline = nil
                self.retryDelay?.cancel()
                self.retryDelay = nil
                self.pendingTicket = nil
                // THE RECOVERY PATH MAY HAVE BEEN THE ONLY THING LEFT, and ending the outage
                // retires it. During a retry delay there is no runner — `startOutageClock` and
                // `finishAttempt` both null it, and only `startAuthorizedAttempt` rebuilds one
                // — so a wake here cancelled the delay that was going to rebuild it and left
                // nothing at all: no runner, no armed timer, no tick, and no surrender
                // reported. A permanent blackhole that also violates `INV-CHAIN-3`, which
                // says something is always armed inside the budget — outside the suspension
                // exemption, which this is not: nothing here is suspended.
                //
                // So a wake with no runner starts a fresh outage rather than merely ending the
                // old one. The budget is genuinely refunded — that is the point of the paired
                // wake — and the new clock arms a new attempt on the network the device has
                // just woken onto.
                // pinned: ChainedOutageDriverTests.testWakingDuringARetryDelayLeavesSomethingArmed
            }
            // STILL OFFLINE MEANS STILL QUIESCED. `wake()` clears the SUSPENSION latch; it has
            // no authority over the path one. Rebuilding here arms retries and deadlines against
            // a network that is still absent, and those one-shot handlers do not check the
            // quiesce state — so they fire and surrender chaining while the device has no
            // network at all. The unsatisfied branch above can leave `runner == nil` (it tears
            // down during a retry delay), which is precisely the shape that reaches the rebuild
            // below (Codex, PR #492).
            // pinned: ChainedOutageDriverTests.testAPairedWakeWhileStillOfflineDoesNotRebuild
            guard !self.isOffline else { return }
            // A transition that arrived while suspended is consumed HERE rather than dropped.
            if self.pendingPathRecovery {
                self.pendingPathRecovery = false
                // Subsumed: the full recovery re-runs the socket half on the woken path, so
                // a settle interrupted by the same sleep has nothing left to defer.
                self.pendingSettledRecovery = false
                self.recoverAfterPathChange(atSeconds: now)
                return
            }
            // The socket half of a burst the sleep interrupted — already counted, so it runs
            // the recovery's SOCKET half directly rather than replaying a transition.
            if self.pendingSettledRecovery {
                self.pendingSettledRecovery = false
                self.performPathSocketRecovery(atSeconds: now)
                return
            }
            // NO RUNNER MEANS REBUILD, whether or not an outage was being timed. During a retry
            // delay there is none because the ladder has not built one yet; after a session
            // ended while suspended there is none because that end retired it. Both leave
            // nothing that can carry traffic, and only a fresh outage builds a session.
            // pinned: ChainedOutageDriverTests.testAWakeRebuildsARunnerThatEndedWhileSuspended
            if self.runner == nil {
                self.beginOutage(atSeconds: now)
                return
            }
            // A SURVIVING RUNNER IS RE-ARMED, not merely kept. Clearing the liveness above is
            // right — a sample taken before the device slept says nothing about the network it
            // woke onto — but on its own it leaves a runner whose handshake was already in
            // flight unable to arm anything again: `tick()`'s retransmissions are `.unobliging`
            // by construction, and an outbound packet offered while a handshake is in progress
            // is QUEUED by the engine rather than sent, so it produces no obliging send either.
            // The silence clock would then stay unarmed through an unreachable peer until the
            // engine's own ~90 s expiry, well past the bound this driver exists to hold
            // (Codex, PR #483).
            //
            // `forceHandshake` fixes both halves at once: it passes `force_resend`, so it is
            // not suppressed by the handshake already in flight, and it reaches `perform` as an
            // `.obliging` send, so it re-arms the clock it just cleared. Re-handshaking on wake
            // is also what the new network wants regardless of detection.
            // pinned: ChainedOutageDriverTests.testWakingWithALiveRunnerReArmsTheSilenceClock
            self.runner?.forceHandshake()
            self.rescheduleTick()
    }

    /// The tunnel is tearing down: shut the session down, disarm everything, and go inert.
    ///
    /// The teardown funnel's half of this driver's lifetime, and the only way its memory is
    /// ever reclaimed: the driver and its runner hold each other strongly (the runner's
    /// `events` sink IS this driver), so `deinit` cannot break the cycle — dropping the last
    /// external reference while a session lives leaks the engine, its buffers and this
    /// supervisor inside the ~50 MB NE ceiling (`INV-MEM-1`). Retiring shuts the runner down
    /// and releases it, which is what lets both halves deallocate.
    ///
    /// TERMINAL, unlike ``sleep()``: nothing clears `isRetired`, so after this returns every
    /// entry point is a no-op — a late `wake()` cannot begin a fresh outage, a `pathChanged`
    /// cannot arm a recovery, an already-queued session end decides nothing, and `adopt`
    /// refuses a new runner. The one-shot SLOTS are cleared for the same reason ``sleep()``
    /// clears them: `cancel()` cannot retract a handler the queue already holds, and a stale
    /// slot still satisfies its handler's serial guard (Codex, PR #483). `INV-CHAIN-3`'s
    /// armed-budget rule ends here exactly as it ends at a surrender: the tunnel that owned
    /// the routes an outage would blackhole is going away.
    ///
    /// Idempotent, and callable from any queue.
    /// pinned: ChainedOutageDriverTests.testRetiringShutsDownAndReleasesTheRunner
    /// pinned: ChainedOutageDriverTests.testARetiredDriverIsInertOnEveryEntryPoint
    /// pinned: ChainedOutageDriverTests.testRetiringMidOutageDisarmsEverything
    public func retire() {
        engineQueue.run {
            self.isRetired = true
            self.timers.scheduleTick(every: nil, leeway: .milliseconds(0))
            self.outageDeadline?.cancel()
            self.outageDeadline = nil
            self.retryDelay?.cancel()
            self.retryDelay = nil
            self.healthyForwardingRetry?.cancel()
            self.healthyForwardingRetry = nil
            self.pendingTicket = nil
            // The QUEUED ends go too, not only the slots — so "after a retirement: nothing
            // is armed" holds by construction rather than by argument. The argument it
            // replaces is real but three steps deep: a drain's outage is always still
            // timing by the time a second end processes (the first end started it), so
            // `finishAttempt` skips `startOutageClock`, `rescheduleTick` is
            // quiesce-gated, and `hasSurrendered` blocks a re-surrender. Every reachable
            // path is therefore already inert, which is why this line carries no pin: no
            // test can observe its removal today. It exists so a future change to any one
            // of those three guards cannot quietly re-open the drain.
            self.pendingEnds.removeAll()
            self.retireLiveAttempt()
            self.rebindConfirmation?.cancel()
            self.rebindConfirmation = nil
            self.settledPathRecovery?.cancel()
            self.settledPathRecovery = nil
            self.pendingSettledRecovery = false
            self.pendingPathRecovery = false
            self.absorbRunnerTallies()
            self.runner?.shutdown()
            self.runner = nil
        }
    }

    /// The monitored network path changed.
    ///
    /// THE ENTRY POINT THIS DRIVER DID NOT HAVE. Until now its whole surface was `adopt`,
    /// `handleOutboundBatch`, `tick`, `sleep`, `wake`, `snapshotCounters`, `isTimingAnOutage`,
    /// `hasSurrenderedChaining` and `sessionEnded` — nothing could tell it the network moved. A
    /// Wi-Fi to cellular handoff, or walking into a lift, therefore arrived as SILENCE: the
    /// link-silence threshold expires, an outage opens, the whole blackhole budget is spent
    /// dialling a path that may no longer exist, and `hasSurrendered` latches. Chained mode is
    /// then off for the rest of the tunnel's life over a fault that was never the upstream's,
    /// on a network the device never tried.
    ///
    /// Three proven implementations make path change their PRIMARY remediation signal, and for
    /// wireguard-apple it is essentially the only app-level policy there is.
    ///
    /// ## Unsatisfied is not a fault
    ///
    /// With no network there is nothing to dial and nothing being blackholed — the user has no
    /// internet either way, so the tunnel holding `0.0.0.0/0` costs them nothing extra. This is
    /// the same argument ``sleep()`` rests on, and it earns the same treatment: quiesce, and end
    /// any outage in progress rather than let it run down against a path that is gone. Mullvad's
    /// equivalent is `stopMonitoring(resetRetryAttempt: true)` plus a `tryStart` that refuses
    /// while offline.
    ///
    /// ## Satisfied-and-changed is EVIDENCE, not fault
    ///
    /// A new path is the best reason to re-handshake there is, and the body is the paired-wake
    /// branch: drain the stale liveness sample, clear the silence clock, and force a handshake —
    /// or build a session if the ladder has not left one.
    ///
    /// ## What this deliberately does NOT do
    ///
    /// It does not refund the budget, and it acts only on a TRANSITION. `NWPathMonitor` delivers
    /// repeated satisfied updates for reasons that are not transitions, and clearing the silence
    /// clock on each would postpone detection indefinitely — the identical defect
    /// `testAnUnpairedWakeDoesNotPostponeDetection` exists to prevent, arriving through the door
    /// beside it.
    ///
    /// ACCEPTED, and named rather than hidden: a genuinely FLAPPING path can keep chained mode
    /// from ever surrendering, because each satisfied interval must re-run the full silence
    /// threshold before an outage can open again. That is the right trade — a flapping path has
    /// no working DNS-only mode to surrender to either — but it is a behaviour, not an oversight.
    /// What a flapping path can NO LONGER do is run the socket rebuild 1:1 with its callbacks:
    /// the recovery's socket half is rate-bound by ``pathRecoverySettleSeconds`` (C5), while
    /// the observations above stay per-transition.
    /// pinned: ChainedOutageDriverTests.testAnUnsatisfiedPathEndsTheOutageRatherThanSpendingItsBudget
    /// pinned: ChainedOutageDriverTests.testARepeatedSatisfiedPathUpdateDoesNotPostponeDetection
    /// pinned: ChainedOutageDriverTests.testWakingWhileStillOfflineDoesNotOpenAnOutage
    public func pathChanged(satisfied: Bool, interfacesChanged: Bool) {
        engineQueue.run {
            guard !self.hasSurrendered, !self.isRetired else { return }

            guard satisfied else {
                guard !self.isOffline else { return }
                self.isOffline = true
                self.counters.offlinePathCount += 1
                // A DEFERRED RECOVERY IS SUPERSEDED BY GOING OFFLINE AGAIN. Without this the
                // flag outlives the transition that set it: satisfied-while-suspended sets it,
                // this branch takes the path away again, the paired wake returns early on the
                // offline latch, a later satisfied update recovers immediately — and the flag is
                // STILL set, so the next unrelated sleep/wake consumes it and performs a second
                // full session rebuild, blackholing traffic through its retry delay for nothing
                // (Codex, PR #492).
                // pinned: ChainedOutageDriverTests.testADeferredRecoveryDoesNotOutliveTheTransitionThatSetIt
                self.pendingPathRecovery = false
                self.pendingSettledRecovery = false
                // The same teardown `sleep()` performs, and for the same reason: a cancelled
                // timer whose SLOT is still installed still satisfies its handler's identity
                // guard, so the slots are cleared rather than merely cancelled.
                self.outageDeadline?.cancel()
                self.outageDeadline = nil
                self.retryDelay?.cancel()
                self.retryDelay = nil
                self.pendingTicket = nil
                self.retireLiveAttempt()
                self.rebindConfirmation?.cancel()
                self.rebindConfirmation = nil
                // The coalesced recovery is CANCELLED, not deferred: the path it was going to
                // rebuild onto is gone, and firing onto a dead path is the companion failure
                // the settle window must not add. A later satisfied transition re-enters the
                // recovery machinery on its own.
                self.settledPathRecovery?.cancel()
                self.settledPathRecovery = nil
                if self.supervisor.isTimingAnOutage, let generation = self.generation {
                    self.supervisor.endOutage(in: generation)
                }
                // THE THIRD END SITE, and the one that ends an outage WITHOUT going through
                // `endOutage()`. A tunnel-DNS hold left set here outlives the outage it was
                // holding: the next outage — from ANY cause — is born held, and since its
                // accumulation is empty no `.answered` is coming to release it, so link
                // evidence can never end it and the budget runs to surrender on a working
                // link. A resolver hiccup followed by an ordinary signal loss is the whole
                // trigger. Per-outage state is cleared wherever an outage ends, not only
                // where it ends tidily.
                // pinned: ChainedOutageDriverTests.testGoingOfflineReleasesATunnelDNSHold
                self.outageHeldByTunnelDNS = false
                // Same reasoning for the egress-dead hold: left set here it born-holds the next
                // outage from ANY cause, and with only real forwarding able to release it (and no
                // forwarding coming on a fresh idle session) the budget runs to surrender on a
                // working link. Per-outage state is cleared wherever an outage ends.
                // pinned: ChainedOutageDriverTests.testGoingOfflineReleasesAnEgressDeadHold
                self.outageHeldByEgressDead = false
                self.timers.scheduleTick(every: nil, leeway: .milliseconds(0))
                return
            }

            let wasOffline = self.isOffline
            self.isOffline = false
            // ONLY A TRANSITION ACTS. See the note above on repeated satisfied updates.
            guard wasOffline || interfacesChanged else {
                self.rescheduleTick()
                return
            }

            // DEFERRED WHILE SUSPENDED, not performed. The path monitor can report a satisfied
            // transition between `sleep()` and its paired `wake()`, and recovering there does
            // the two things suspension exists to prevent: `beginOutage` arms one-shots whose
            // handlers do not check the quiesce state — so a long suspension surrenders chaining
            // outright — and a rebuild drives the engine through the interval `sleep()` promised
            // was quiet. The transition is remembered instead, and `wake()` consumes it
            // (Codex, PR #492).
            // pinned: ChainedOutageDriverTests.testASatisfiedPathDuringSuspensionIsDeferredToWake
            guard !self.isSuspended else {
                self.pendingPathRecovery = true
                return
            }

            self.recoverAfterPathChange(atSeconds: self.clock.nowSeconds())
        }
    }

    /// Rebuilds onto the path the device is now on.
    ///
    /// REBUILD, NOT RE-HANDSHAKE, and the codebase already said so before this entry point
    /// existed: ``ChainedUpstreamEgressPolicy/lifecycle(after:boundTo:)`` returns `.rebuild` for
    /// `.pathChanged`, because the channel's socket is pinned to a specific `NWInterface` at
    /// construction (`ChainedUpstreamChannelParameters`: `parameters.requiredInterface = live`).
    /// A surviving runner therefore sends through the interface that just went away, and it
    /// fails SILENTLY — the stale binding does not error, so datagrams go nowhere and the peer
    /// reads as unresponsive rather than the socket reading as broken. Forcing a handshake there
    /// re-handshakes into a dead socket and leaves the handoff blackholed until the 21-second
    /// silence detector eventually tears the session down, which is the exact latency this entry
    /// point exists to remove (Codex, PR #492).
    ///
    /// That policy had ZERO callers. Writing a path-change handler without consulting the
    /// path-change policy is how the first version of this shipped the failure it was fixing.
    ///
    /// The rebuild is a full session rebuild because that is the only one available today —
    /// `ChainedSessionRunner` holds `session` and `channel` as `let`, so the socket cannot be
    /// replaced without replacing the `Tunn`. Making the channel rebindable is its own slice
    /// (benchmark R2); until then a handoff costs a handshake out of the budget instead of one
    /// keepalive, and it starts from the correct path immediately rather than 21 seconds late.
    /// pinned: ChainedOutageDriverTests.testAChangedPathReplacesTheTransportAndNeverReHandshakesIntoTheOldOne
    private func recoverAfterPathChange(atSeconds now: Int) {
        // NO `pendingPathRecovery = false` here, and that is a deletion rather than an omission.
        // A second clear looked prudent and was redundant: `wake()` clears the flag itself when
        // it consumes one, and the only path that reaches this function with a STALE flag is a
        // deferral superseded by a later unsatisfied transition — which the unsatisfied branch
        // now clears at its source. Splitting the mutation proved it: removing either clear
        // alone left every test green, because each one alone covers the sequence.
        //
        // Two clears where one is enforced is not defence in depth, it is an untested branch
        // wearing the costume of one.
        counters.pathRecoveryCount += 1
        // Credit is discarded on BOTH sides, exactly as on a paired wake: the runner's sample is
        // a level, so a `sawInboundData` set on the OLD path would otherwise certify a peer we
        // have not reached since the network changed underneath us.
        _ = takeLivenessSampleReportingForwarding()
        // Socket replacement can be coalesced for several seconds. Invalidate the old path's
        // proof now, even if no app query sees the intermediate recovery window. A replacement
        // transport still gets zero baseline through its distinct counter identity.
        invalidateVerificationEvidenceAfterDrain()
        lastInboundDataAtSeconds = now
        firstUnansweredSendAtSeconds = nil
        channelSaturatedSinceSeconds = nil
        // The tunnel-DNS ACCUMULATION resets with the other detection latches — the network
        // changed, so pre-transition failures are evidence about a path that no longer
        // exists. The HOLD deliberately does not: an OPEN tunnel-DNS outage stays held
        // across a roam, because its disarming observation is a served answer and a roam
        // does not make a dead resolver less dead — clearing it here would let the first
        // post-roam keepalive end the outage, restart the cycle, and never surrender.
        // pinned: ChainedOutageDriverTests.testAPathTransitionDoesNotReleaseATunnelDNSOutage
        clearTunnelDNSAccumulationOnQueue()
        // The egress-dead ACCUMULATION resets with the other detection latches — pre-transition
        // forwarding is about a path that no longer exists — but its HOLD, like the tunnel-DNS
        // hold above, deliberately does not: an OPEN egress-dead outage stays held across a roam,
        // because a roam does not make a broken upstream forward again.
        // pinned: ChainedOutageDriverTests.testAPathTransitionDoesNotReleaseAnEgressDeadOutage
        resetEgressDeadAccumulation()
        // THE SETTLE WINDOW (C5). Everything above runs per transition — observations and
        // clock resets are cheap and correct at any rate. The SOCKET work below is what a
        // flap burst must not run 1:1: each pass builds a fresh socket whose source port
        // supersedes the last before its confirmation can close, and the supervisor never
        // sees the churn because no session ends. One recovery leads the burst; transitions
        // inside the window coalesce into the single trailing recovery armed here, which
        // lands on the burst's FINAL path.
        if let last = lastPathSocketRecoveryAtSeconds,
            now - last < Self.pathRecoverySettleSeconds {
            counters.coalescedPathRecoveryCount += 1
            // NEVER ARMED WHILE AN OUTAGE IS BEING TIMED. `startOutageClock`'s cancel covers
            // timers armed BEFORE the outage opened; a coalesced transition arriving AFTER
            // would re-arm past it, and its fire lands mid-ladder — retiring whatever
            // replacement attempt is live and spending a rung on a socket the ladder was
            // about to build (Codex, PR #504). Recorded as a DEBT instead: the ladder's next
            // attempt satisfies it (a fresh build binds the current path), but an outage that
            // ends on EVIDENCE keeps its runner — no attempt ever runs, and the evidence can
            // arrive through the old interface's brief afterlife — so `endOutage` consumes
            // what is owed and rebinds onto the settled path (Codex, PR #504 round 2).
            if supervisor.isTimingAnOutage {
                pendingSettledRecovery = true
            } else if settledPathRecovery == nil {
                settledPathRecovery = armTimer(
                    atSeconds: last + Self.pathRecoverySettleSeconds
                ) { [weak self] serial in self?.settledPathRecoveryFired(serial: serial) }
            }
            return
        }
        performPathSocketRecovery(atSeconds: now)
    }

    /// A genuine wake/path boundary owns this call after its stale-liveness drain. Reads and
    /// ordinary pending traffic never enter it. This changes only evidence metadata, not recovery.
    private func invalidateVerificationEvidenceAfterDrain() {
        setupRequiresPostWakePeerEvidence = true
        verificationEpoch &+= 1
        if let stats = runner?.sampleStatistics() {
            verificationForwardingBaseline = (
                sessionGeneration, stats.transportGeneration, stats.forwardedNonDNSByteCount)
            unavailableWakeBaselineSession = nil
        } else {
            verificationForwardingBaseline = nil
            unavailableWakeBaselineSession = runner == nil ? nil : sessionGeneration
        }
    }

    /// The socket half of a path recovery — the part the settle window rate-bounds.
    private func performPathSocketRecovery(atSeconds now: Int) {
        lastPathSocketRecoveryAtSeconds = now
        settledPathRecovery?.cancel()
        settledPathRecovery = nil
        // DRAIN THE PRE-SWAP SAMPLE FIRST. The per-transition semantics drained it, but the
        // DEFERRED routes here (the trailing fire, the wake consume, the end-of-outage debt)
        // run seconds later — and a peer answer latched on the outgoing socket in between
        // would be read by the next tick as evidence on the NEW one, cancelling the rebind
        // confirmation and falsely certifying a socket that never carried a byte. The stale
        // credit is discarded, not spent; detection keeps running from the last transition's
        // clock reset (Codex, PR #504).
        _ = takeLivenessSampleReportingForwarding()
        // THE FAST PATH (R2). A path change invalidates the SOCKET, not the session — `Tunn`
        // holds keys and an index, not an endpoint — so replacing just the socket costs one
        // keepalive on the existing keypair instead of the full ladder: `startOutageClock` nulls
        // the runner, `act` arms a RETRY DELAY before a session is even built, then the build,
        // then a handshake, and it spends one of roughly three rungs the budget buys.
        //
        // Only outside an outage. Once one is being timed the ladder owns recovery, and
        // `startOutageClock` may already have nulled the runner.
        // pinned: ChainedOutageDriverTests.testAPathChangeOutsideAnOutageRebindsRatherThanRebuilding
        if runner != nil, !supervisor.isTimingAnOutage, attemptRebind(atSeconds: now) {
            return
        }
        // `beginOutage` -> `startOutageClock` shuts the runner down and nulls it, so this is the
        // rebuild: the ladder builds a fresh session, on a fresh socket, bound to the interface
        // the device is actually on.
        beginOutage(atSeconds: now)
    }

    /// The settle window ended with coalesced transitions inside it — run the one trailing
    /// recovery the burst gets, on whatever path the burst settled on.
    private func settledPathRecoveryFired(serial: UInt64) {
        engineQueue.requireOnQueue()
        guard !hasSurrendered, !isQuiesced, settledPathRecovery?.serial == serial else { return }
        settledPathRecovery = nil
        // AN OUTSTANDING CONFIRMATION RESOLVES FIRST. It and this timer share one interval
        // measured from the same instant, and dispatch does not order two independent
        // sources due together — so this fire landing first would cancel a still-pending
        // confirmation inside `attemptRebind` and grant the NEXT socket a fresh window: a
        // dead path claimed for six seconds instead of the documented three, and a
        // continuing burst could postpone the fallback indefinitely (Codex, PR #504). One
        // last sample lets late evidence confirm the leading socket — evidence latched
        // before the swap belongs to it, exactly as `rebindUnconfirmed` credits it — and a
        // survivor is unconfirmed AT its own deadline, so it falls back exactly as its own
        // fire would have.
        if rebindConfirmation != nil {
            sampleLiveness()
            // The sample can open an outage on its own (silence plus demand); the ladder
            // then owns recovery and builds the fresh socket itself.
            if supervisor.isTimingAnOutage { return }
            if rebindConfirmation != nil {
                // CANCELLED, not merely cleared. Unlike `rebindUnconfirmed`'s own path —
                // which runs because that timer just fired — this one is still armed, and
                // every other site retiring a live confirmation cancels it (`sleep`, the
                // unsatisfied path, `startOutageClock`). Clearing the slot alone leaves a
                // source that wakes the engine queue to be rejected by its serial guard:
                // harmless to decide, a wake the driver's own timer discipline exists to
                // not spend.
                rebindConfirmation?.cancel()
                rebindConfirmation = nil
                counters.rebindUnconfirmedCount += 1
                beginOutage(atSeconds: clock.nowSeconds())
                return
            }
        }
        performPathSocketRecovery(atSeconds: clock.nowSeconds())
    }

    /// Swaps the transport under a live session, and arms a deadline to prove it worked.
    ///
    /// Returns false when the rebind could not be attempted or could not be trusted, and the
    /// caller then does exactly what it did before R2. Every failure direction here falls back
    /// rather than forward: a channel that cannot be built, a runner that refuses, and a session
    /// with no current keypair all end in a full rebuild.
    ///
    /// THE CONFIRMATION IS NOT OPTIONAL. The keepalive obliges the peer nothing, so its going
    /// out is not evidence the new socket works — and a claimed `0.0.0.0/0` with nothing armed
    /// is the blackhole `INV-CHAIN-3` exists to forbid. The deadline is what keeps the fast
    /// path's worst case at "R1, at most two windows late" (one re-anchor retry, then R1) instead
    /// of "R1, never".
    /// pinned: ChainedOutageDriverTests.testAnUnconfirmedRebindFallsBackToAFullRebuild
    private func attemptRebind(atSeconds now: Int) -> Bool {
        guard let runner else { return false }
        guard let replacement = try? source.makeChannel(engineQueue: engineQueue) else {
            // No eligible interface, or an unbindable one. The old channel is untouched and the
            // session is still whole; the ladder is the right owner of a network that cannot
            // currently be bound at all.
            return false
        }

        switch runner.adoptChannel(replacement) {
        case .rebound:
            counters.rebindCount += 1
            // Fresh rebind: restore this confirmation's one-retry budget.
            rebindReanchorRetried = false
            rebindConfirmation?.cancel()
            rebindConfirmation = armTimer(atSeconds: now + Self.rebindConfirmationSeconds) {
                [weak self] serial in self?.rebindUnconfirmed(serial: serial)
            }
            rescheduleTick()
            return true
        case .noCurrentSession, .refused:
            // `adoptChannel` closed the replacement itself on both of these, so nothing leaks.
            counters.rebindDeclinedCount += 1
            return false
        }
    }

    /// The rebind did not prove itself in time. A LONE rebind gets one bounded re-anchor retry
    /// first; a second miss (or a rebind caught in a flap burst) falls back to what R1 did.
    private func rebindUnconfirmed(serial: UInt64) {
        engineQueue.requireOnQueue()
        guard !hasSurrendered, !isQuiesced, rebindConfirmation?.serial == serial else { return }

        // ONE LAST SAMPLE BEFORE DECIDING, because evidence the runner has already latched is not
        // evidence this driver has READ. The two clocks do not line up: the tick that drains
        // liveness repeats every 500 ms with 50 ms of leeway, while this deadline has none — so a
        // peer that answered up to ~550 ms before the timer fires has its answer sitting in an
        // undrained sample. Tearing down on that is the exact false outage the confirmation
        // exists to avoid, and it costs the user the full retry ladder on a link that works
        // (Codex, PR #493).
        //
        // `sampleLiveness` clears `rebindConfirmation` when it finds evidence, so the guard below
        // is how the answer comes back. It can also START an outage on its own — silence plus
        // demand — and that path runs `startOutageClock`, which cancels the confirmation too; the
        // guard covers both, so neither double-counts.
        // pinned: ChainedOutageDriverTests.testEvidenceArrivingAfterTheLastTickStillConfirmsTheRebind
        sampleLiveness()
        guard rebindConfirmation?.serial == serial else { return }

        // ONE BOUNDED RE-ANCHOR RETRY before the expensive rebuild — but only for a LONE rebind.
        // The rebind's re-anchor is a single `.unobliging` keepalive (`ChainedSessionRunner.
        // adoptChannel`), so one lost datagram on a WORKING new path reads as unconfirmed and used
        // to spend a full rebuild: a fresh handshake AND connect-gate establishment, the worst
        // roam-recovery latency (device evidence 2026-08-23 — a real roam hit `rebindUnconfirmedCount`
        // → `outageCount` and blackholed the App Store). Re-anchor once with a FORCED HANDSHAKE —
        // obliging and engine-retransmitted (`force_resend`), so it survives the loss the keepalive
        // did not, and it re-anchors the peer on the new path exactly as the wake path does — then
        // grant one more window sized (``rebindReanchorRetrySeconds``) to outlast the engine's own
        // `REKEY_TIMEOUT` retransmit, so even a lost initiation's resend lands and confirms. Only a
        // SECOND miss rebuilds, so a genuinely dead path still falls back, one window later.
        //
        // GATED ON NO PENDING SETTLE RECOVERY, so a flap BURST keeps PR #504's bounded fallback:
        // with a trailing recovery still due, retrying the superseded socket would (a) reintroduce
        // the race-order asymmetry #504 removed — a dead path claimed six seconds one fire order,
        // three the other — and (b) re-anchor a socket the burst is already settling PAST. A burst
        // falls back immediately in either fire order (here and in `settledPathRecoveryFired`); the
        // retry is exactly the lone-roam case the device evidence showed.
        // pinned: ChainedOutageDriverTests.testAnUnconfirmedRebindRetriesTheReAnchorBeforeRebuilding
        // pinned: ChainedOutageDriverTests.testAReanchorRetryThatConfirmsAvoidsTheRebuild
        // pinned: ChainedOutageDriverTests.testARebindInAFlapBurstDoesNotGetTheReAnchorRetry
        if !rebindReanchorRetried, runner != nil, settledPathRecovery == nil, !pendingSettledRecovery {
            rebindReanchorRetried = true
            counters.rebindReanchorRetryCount += 1
            runner?.forceHandshake()
            rebindConfirmation = armTimer(atSeconds: clock.nowSeconds() + Self.rebindReanchorRetrySeconds) {
                [weak self] serial in self?.rebindUnconfirmed(serial: serial)
            }
            return
        }

        rebindConfirmation = nil
        counters.rebindUnconfirmedCount += 1
        beginOutage(atSeconds: clock.nowSeconds())
    }

    /// One tunnel-DNS resolution's outcome (S6).
    public enum TunnelDNSObservation: Sendable, Equatable {
        /// The tunnelled resolver produced a valid answer — a TC one included. TC is the
        /// resolver replying, promptly and correctly, that the response does not fit UDP
        /// (`ChainedResolverEgressPolicy.truncationIsResolverLiveness`); reporting it as
        /// anything else lets one large-response domain spend the outage budget.
        case answered
        /// A query was sent through the tunnel and nothing valid came back inside its
        /// budget. `nameKey` is an opaque key of the normalized query name — the driver
        /// never sees a name, and the key exists only so the declaration can require
        /// failures across DISTINCT names.
        ///
        /// ONLY the sent-and-unanswered shape belongs here, and the producer's obligation is
        /// wider than it looks: ANY valid DNS response is `.answered`, including SERVFAIL,
        /// NXDOMAIN and REFUSED — and a truncated one, which is this decision's named trap.
        /// Those are a resolver ANSWERING, which is the whole question this cause asks; only
        /// silence is evidence it is gone. Local refusals — no port claim, no interface, a
        /// mismatched response storm — are not evidence about the resolver either, and
        /// reporting them would arm the budget on conditions a rebuild cannot fix.
        case unanswered(nameKey: UInt64)

        /// The canonical key for a normalized query name — FNV-1a over its UTF-8 bytes.
        ///
        /// Lives beside its consumer so "distinct keys" and "distinct names" stay one
        /// fact: the declaration floor counts distinct KEYS, and a producer hashing
        /// differently per call site would let one name arm as two. Unseeded and
        /// deterministic on purpose — the keys never outlive the driver, and the
        /// chosen-traffic attacker this cause defends against manufactures distinct
        /// NAMES for free, so collision resistance buys nothing here; the defence is
        /// ``maximumTunnelDNSOutagesPerLifecycle``, not the hash.
        /// pinned: ChainedOutageDriverTests.testTheNameKeyIsOneFactPerNormalizedName
        public static func nameKey(forNormalizedName name: String) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in name.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return hash
        }
    }

    /// Reports that the physical T1 rung SERVED a name the tunnelled resolver did not.
    ///
    /// "The rung" means the whole ladder beneath T0 — the user's selected resolver and whatever
    /// fallback they chose beneath it alike (`ResolverOrchestrator.TierOneRungEvidence`'s
    /// `ladderServed`). The claim is about the USER, not about any one tier: they asked for
    /// something to answer when T1 cannot, and when it answers they were not blackholed.
    ///
    /// THE TUNNEL-DNS CAUSE IS ABOUT THE USER LOSING DNS, not about T0's own health, and those
    /// stopped being the same question when the rung landed. Its disarming observation was a
    /// served answer FROM T0 — so a T0 that structurally cannot answer a class of names holds
    /// the outage open until the budget runs out and surrenders a session whose DNS the rung was
    /// serving perfectly the whole time.
    ///
    /// Field evidence (2026-09-01, two captures): a split-tunnel Tailscale profile with
    /// `DNS = 100.100.100.100` and `AllowedIPs = 100.64.0.0/10`. MagicDNS answers tailnet names
    /// and drops public ones, so every public query was a tunnelled non-answer the rung then
    /// rescued. Two surrenders — 07:18 and 09:35 — both `hasHandshake: true` with 468 KB and
    /// 2.7 MB flowing, and 204 public names resolved in the window before the second one. The
    /// tunnel was healthy, the user's DNS was working, and chaining surrendered anyway.
    ///
    /// NO ROUTING-POLICY TERM HERE, and none is needed: the rung is permitted only under a split
    /// tunnel (``ChainedResolverEgressPolicy/permitsTierOneFallbackOnPhysicalInterface``), so a
    /// rescue cannot exist in a full tunnel. The evidence's existence IS the policy check, which
    /// is stronger than re-deriving one — a full tunnel keeps the strict rule structurally rather
    /// than by a conditional someone could widen.
    ///
    /// NOT a claim that the tunnel works, and deliberately weaker than ``TunnelDNSObservation``'s
    /// `.answered`: the rung egresses PHYSICALLY, so it proves nothing about the session. It
    /// refunds no budget, ends no link outage, and sets no liveness credit. It says one thing —
    /// the user was not blackholed — and that is exactly the premise the tunnel-DNS hold rests on.
    /// pinned: ChainedOutageDriverTests.testARungRescueDisarmsTheTunnelDNSCauseWithoutClaimingTheTunnelWorks
    public func reportTierOneRungRescue() {
        // Same producer-door contract as `reportTunnelDNSObservation`: callable from any queue,
        // enqueued rather than run, never load-bearing for the answer the caller already has.
        //
        // THE LOCK IS NOT CEREMONY HERE, even though this door stamps no clock. It buys ORDER
        // against the observation door, which is exactly what this pairing needs: one resolution
        // reports T0's `.unanswered` first and this rescue second, and the serial queue's FIFO
        // turns that submission order into handling order only while both doors serialize on the
        // same lock. Handled newest-first instead, the rescue disarms a cause the miss then
        // re-arms — the rescue silently lost, and the surrender it was meant to prevent still
        // happens (the ordering hazard `testAPreemptedProducerCannotReorderObservations` records).
        observationSubmission.lock()
        engineQueue.enqueue { [weak self] in
            self?.handleTierOneRungRescueOnQueue()
        }
        observationSubmission.unlock()
    }

    private func handleTierOneRungRescueOnQueue() {
        engineQueue.requireOnQueue()
        guard !hasSurrendered, !isRetired else { return }
        counters.tierOneRungRescueObservationCount += 1
        let held = outageHeldByTunnelDNS
        // The CAUSE is disarmed, for the same reason an answer disarms it: its premise is that
        // the user is losing DNS, and the rescue is proof they are not.
        outageHeldByTunnelDNS = false
        // Only an outage THIS cause holds, and only with a session still under us — the same two
        // guards `.answered` carries, for the same reasons: a link outage is not ours to close,
        // and ending one with no runner leaves nothing armed and no surrender reported
        // (`INV-CHAIN-3`, Codex PR #513).
        //
        // RETIRING ON THE QUEUE, NOT AT SUBMISSION, and that ordering was raised (Codex P2,
        // PR #639): a `.unanswered` submitted after this rescue but before it is handled stamps
        // the pre-retirement epoch and is then dropped as stale, even though the lock makes it
        // the newer submission. The shape is real and it is `reportTunnelDNSObservation`'s too —
        // `.answered` has retired on the queue since PR #513 — so it is not this door's to change
        // unilaterally, and moving the bump to submission would retire twice per event, which is
        // exactly the defect `testAnAnswerRetiresTheObservationWindowExactlyOnce` pins against.
        //
        // It is also bounded and, here, harmless. The dropped observation is counted
        // (`tunnelDNSStaleObservationCount`), so it is visible rather than silent; a rescue
        // already discards the accumulation deliberately, so the epoch adds nothing the clear
        // was not doing; and once the ladder stops serving there are no more rescues, hence no
        // more retirements, and the following misses accumulate normally. Detection is delayed
        // by at most the observations in flight across one queue hop — never prevented — and
        // only while the ladder is still answering, which is the state that must not declare.
        if held, supervisor.isTimingAnOutage, runner != nil {
            endOutage()
        } else {
            clearTunnelDNSAccumulationOnQueue()
        }
    }

    /// Reports a tunnel-DNS resolution outcome from the provider's resolution path (S6).
    ///
    /// The producer door `pathChanged` is the pattern for: callable from any queue (the
    /// provider calls it with an ASYNC hop off `dnsStateQueue` — a synchronous wait would
    /// couple the two confinements, `INV-QUEUE-1`), self-gating, and never load-bearing for
    /// the answer the caller already has. Deliberately NOT a `ChainedLivenessSample` field:
    /// the sample channel is read-and-clear with drain sites that DISCARD stale credit —
    /// the right lifetime for recovery credit, the wrong one for failure evidence — and the
    /// tick that pulls it stops during retry delays, exactly when a dead resolver's
    /// evidence accumulates.
    public func reportTunnelDNSObservation(_ observation: TunnelDNSObservation) {
        // ENQUEUE, not `run`. The doc above obliges the caller to hop asynchronously off
        // `dnsStateQueue`; `run` is a `queue.sync` from any other queue, so the obligation
        // was prose the seam could not enforce — one direct call from the resolution path
        // would park a DNS completion behind whatever holds the engine queue (a batch, a
        // handshake, a bounded Keychain read) and couple the two confinements the hard way,
        // which is the deadlock shape `INV-QUEUE-1` exists to forbid. Making the hop
        // structural also costs the caller nothing: this reports an outcome it already has,
        // and nothing downstream waits on the answer.
        // pinned: ChainedOutageDriverTests.testTheObservationDoorNeverBlocksItsCaller
        //
        // STAMPED HERE, NOT WHERE IT RUNS. The hop is asynchronous, so reading the clock in
        // the handler measures queue latency as part of the failure interval: a first
        // observation delayed a second and a second one processed promptly makes failures
        // 21 s apart look 20 s apart. Declaration is event-driven and arms no timer, so
        // that false negative is never re-evaluated — with sparse queries a dead resolver
        // then fails closed indefinitely — and the inverse delay manufactures an outage
        // that never happened (Codex, PR #513). The occurrence time belongs to the
        // observation, so it travels with it.
        // pinned: ChainedOutageDriverTests.testAnObservationIsTimedWhenItHappensNotWhenItIsHandled
        // STAMPING AND SUBMITTING ARE ONE STEP. Splitting them reintroduces the disorder the
        // stamp exists to prevent, from the other side: this door is `Sendable` and may be
        // called concurrently, so a producer preempted between the clock read and the
        // `enqueue` lets a LATER observation — or a wake, or a path reset — reach the queue
        // first. The older event is then handled in the newer epoch: a pre-transition
        // timeout seeds the post-transition accumulation, or two failures a threshold apart
        // are processed newest-first and never declare, because the second one's stamp is
        // already installed and the first reads as negative elapsed (Codex, PR #513).
        //
        // A LOCK AND AN EPOCH, doing two different jobs — and the first version of this note
        // claimed the lock made the epoch unnecessary, which was wrong in a way worth
        // recording. The lock orders observations against EACH OTHER: with submission
        // serialized against the read, a serial queue's FIFO makes handling order equal
        // stamping order, so no observation submitted through this door is ever stale
        // relative to another. What it cannot order is the RESETS — `wake`, `pathChanged`,
        // and the recoveries submit without taking it — so an observation stamped while a
        // reset is already queued ahead of it is handled in a window that no longer exists.
        // That is what the epoch retires, and it is why the two coexist rather than one
        // replacing the other (Codex, PR #513).
        //
        // The lock is held across two non-blocking operations — a clock read and an `async` —
        // so it cannot become the caller-blocking hazard the async hop exists to avoid. That
        // obligation is load-bearing in the other direction too: `clearTunnelDNSAccumulationOnQueue`
        // takes this lock FROM the engine queue, so anything that could block inside here
        // would deadlock it.
        // pinned: ChainedOutageDriverTests.testAPreemptedProducerCannotReorderObservations
        observationSubmission.lock()
        let observedAtSeconds = clock.nowSeconds()
        let epoch = observationEpoch
        engineQueue.enqueue { [weak self] in
            self?.handleTunnelDNSObservationOnQueue(
                observation, atSeconds: observedAtSeconds, epoch: epoch)
        }
        observationSubmission.unlock()
    }

    private func handleTunnelDNSObservationOnQueue(
        _ observation: TunnelDNSObservation, atSeconds observedAt: Int, epoch: UInt64
    ) {
        engineQueue.requireOnQueue()
        guard !hasSurrendered, !isRetired else { return }
        switch observation {
        case .answered:
            counters.tunnelDNSAnsweredObservationCount += 1
            // A served answer is this cause's disarming observation (C4), and it ends the
            // outage ITSELF rather than clearing the hold and waiting for the next sample
            // to notice. The earlier version relied on the answer's own delivery having set
            // `sawInboundData` so the shared predicate would converge — but the liveness
            // sample is READ-AND-CLEAR and the packet is delivered before the resolution
            // completes, so an ordinary tick in between consumes that evidence while the
            // hold is still set. The hold then clears with nothing left to observe, and if
            // no further authenticated datagram happens to arrive the outage runs to
            // surrender on a resolver that had recovered (Codex + Kilo, PR #513).
            //
            // Ending directly is also the honest reading of the rule: the observation that
            // disarms a cause is the one that ends the outage that cause holds.
            // pinned: ChainedOutageDriverTests.testAnAnsweredObservationAloneEndsADNSHeldOutage
            let held = outageHeldByTunnelDNS
            // The CAUSE is disarmed by the answer unconditionally — that much is just what the
            // observation means. Whether the OUTAGE ends is the separate question below.
            outageHeldByTunnelDNS = false
            // Only an outage THIS cause holds. A link outage has its own disarming observation
            // and is not ours to close: DNS answering proves the link carried one datagram,
            // which is not the same claim the link arm makes.
            //
            // AND ONLY WITH A SESSION STILL UNDER US. `startOutageClock` shuts the runner down
            // and nulls it the moment this cause declares, and only `startAuthorizedAttempt`
            // builds another — so an answer arriving during the retry delay that follows a
            // declaration reaches an outage with NO runner. Ending it there cancelled the retry
            // delay and the deadline while `rescheduleTick` cancelled the tick for want of a
            // runner, leaving no session, nothing armed, and no surrender reported: a permanent
            // blackhole, and an `INV-CHAIN-3` violation outside the suspension exemption
            // (Codex, PR #513). This is the same defect the paired wake was caught committing
            // in PR #483 — see `wake()`'s note — reached through a door that did not exist then.
            // Every OTHER caller of `endOutage()` happens to hold a runner: `sampleLiveness`
            // reaches it only through evidence it took from `runner`, so this arm is the first
            // that can call it without one.
            //
            // Not ended, rather than ended-and-rebuilt, because the budget is NOT refunded here
            // — that is what distinguishes this from the wake, which really does buy fresh time.
            // An answer with no session is evidence about a session that no longer exists, and
            // there is no coherent sense in which tunnel DNS is working while nothing carries
            // it. So the ladder the declaration started runs on, bounded by the budget it
            // already had, and the rebuilt session's own inbound data ends the outage through
            // `sampleLiveness` — which the cleared hold above now permits.
            // pinned: ChainedOutageDriverTests.testAnAnswerDuringTheRetryDelayLeavesSomethingArmed
            if held, supervisor.isTimingAnOutage, runner != nil {
                // ONE RETIREMENT PER ANSWER, which is why the clear is in this branch rather
                // than above it: `endOutage()` retires the window itself, so clearing here as
                // well advanced the epoch TWICE for a single logical retirement. A producer
                // that stamped a genuinely new failure between the two updates was then dropped
                // by the gate, and with sparse DNS traffic that erased the first failure of the
                // new window — a dead resolver that could never reach the declaration predicate
                // again (Codex, PR #513).
                // pinned: ChainedOutageDriverTests.testAnAnswerRetiresTheObservationWindowExactlyOnce
                endOutage()
            } else {
                clearTunnelDNSAccumulationOnQueue()
            }
        case .unanswered(let nameKey):
            counters.tunnelDNSUnansweredObservationCount += 1
            // No accumulation while quiesced, while no session is nominally carrying, or
            // while an outage is already being timed — the same shape as the link arms,
            // which only declare outside an outage. During an outage the runner is down for
            // whole stretches, so timeouts there are EXPECTED and say nothing about the
            // resolver; counting them would let a link outage acquire a DNS hold it must
            // never have (a recovered link would then wait on DNS traffic that may never
            // come, and surrender a healthy tunnel).
            // pinned: ChainedOutageDriverTests.testTimeoutsDuringALinkOutageDoNotHoldIt
            // THE EPOCH GATE IS ON THE ARMING PATH ONLY, and the asymmetry is deliberate.
            // Stale evidence must never ARM: an observation that outlived its window
            // describes a resolver on a path that no longer exists. But `.answered` is
            // recovery evidence, and dropping a stale one would leave a DNS-held outage
            // waiting for an answer that may never come — surrendering a resolver that had
            // recovered, which is the worse failure and the one this cause was already
            // caught making. Ambiguity resolves toward answered here exactly as it does in
            // `sampleLiveness`.
            // COUNTED, because otherwise nothing observable distinguishes an observation the
            // epoch DROPPED from one a reset merely cleared afterwards: the tally above
            // increments before this gate, so both interleavings read identically and a test
            // staged on the wrong one passes while proving nothing (Kilo, PR #513).
            guard epoch == observationEpoch else {
                counters.tunnelDNSStaleObservationCount += 1
                return
            }
            guard !isQuiesced, runner != nil, !supervisor.isTimingAnOutage,
                tunnelDNSDeclarationCount < Self.maximumTunnelDNSOutagesPerLifecycle
            else { return }
            // The observation's OWN time, carried from the door — never the handler's, which
            // would fold queue latency into the interval (see `reportTunnelDNSObservation`).
            let now = observedAt
            if firstUnansweredTunnelDNSAtSeconds == nil {
                firstUnansweredTunnelDNSAtSeconds = now
            }
            // Capped at the count the declaration decides on — see the field's own note.
            if unansweredTunnelDNSNameKeys.count < 2 {
                unansweredTunnelDNSNameKeys.insert(nameKey)
            }
            // Declaration: sustained (the threshold) AND resolver-scoped (two distinct
            // names). Event-driven on purpose — no timer to arm, no tick to depend on; a
            // sparse failure stream (one query a minute against a dead resolver) still
            // declares on the first failing observation past the threshold. The window is
            // NOT restarted on gaps: with zero answers in between, "the last N resolutions
            // all failed across ≥2 names" is the best evidence available, a wrong
            // declaration costs one bounded rebuild cycle that the first served answer
            // ends, and a window that restarts on gaps never declares for exactly the
            // sparse traffic a dead resolver produces — unbounded fail-closed.
            guard let first = firstUnansweredTunnelDNSAtSeconds,
                now - first >= Self.tunnelDNSUnservedThresholdSeconds,
                unansweredTunnelDNSNameKeys.count >= 2
            else { return }
            counters.tunnelDNSOutageCount += 1
            tunnelDNSDeclarationCount += 1
            outageHeldByTunnelDNS = true
            beginOutage(atSeconds: now)
        }
    }

    /// The tallies, read from anywhere.
    public func snapshotCounters() -> ChainedDriverCounters {
        engineQueue.run {
            var counters = self.counters
            // Stamped live at snapshot rather than mirrored on every transition — one read on the
            // engine queue, consistent with the rest of the snapshot.
            counters.isSuspended = self.isSuspended
            // The LIVE runner's pressure tallies, overlaid on the retired totals already folded
            // into `self.counters` — see `absorbRunnerTallies`. The runner's read is re-entrant
            // on this queue, exactly as `snapshotStatistics()`'s is.
            if let live = self.runner?.snapshotCounters() {
                counters.dnsHandledPacketCount += live.dnsHandledPacketCount
                counters.malformedPacketCount += live.malformedPacketCount
                counters.unfilterableDNSPacketCount += live.unfilterableDNSPacketCount
                counters.unfilterableEncryptedDNSPacketCount += live.unfilterableEncryptedDNSPacketCount
                counters.droppedIPv6Count += live.droppedIPv6Count
                counters.encapsulationAttemptCount += live.encapsulationAttemptCount
                counters.shedPacketCount += live.shedPacketCount
                counters.refusedOutboundBacklogPacketCount += live.refusedOutboundBacklogPacketCount
                counters.refusedInboundBacklogDatagramCount += live.refusedInboundBacklogDatagramCount
                counters.sendCompletionErrorCount += live.sendCompletionErrorCount
                counters.sendToPeerCount += live.sendToPeerCount
                // ASSIGNED, not accumulated: these two are levels the runner stamps from its live
                // destination table, so `+=` would add a wait nothing is still waiting on. With no
                // runner they stay at zero, which is the honest reading — nothing is being asked.
                counters.unansweredDestinationCount = live.unansweredDestinationCount
                counters.longestUnansweredDestinationSeconds =
                    live.longestUnansweredDestinationSeconds
            }
            return counters
        }
    }

    /// Folds the current runner's data-path tallies into this driver's counters — called
    /// wherever a runner is retired, BEFORE its `shutdown()`/nil, so the surfaced totals stay
    /// monotonic across session rebuilds. Without this every rebuild silently zeroed the
    /// pressure counters mid-window and a 60 s delta could read negative — or worse, a real
    /// shed could vanish into a rebuild and read as "no pressure".
    /// pinned: ChainedOutageDriverTests.testARetiredRunnersPressureTalliesSurviveTheRebuild
    private func absorbRunnerTallies() {
        guard let runner else { return }
        let tallies = runner.snapshotCounters()
        counters.dnsHandledPacketCount += tallies.dnsHandledPacketCount
        counters.malformedPacketCount += tallies.malformedPacketCount
        counters.unfilterableDNSPacketCount += tallies.unfilterableDNSPacketCount
        counters.unfilterableEncryptedDNSPacketCount += tallies.unfilterableEncryptedDNSPacketCount
        counters.droppedIPv6Count += tallies.droppedIPv6Count
        counters.encapsulationAttemptCount += tallies.encapsulationAttemptCount
        counters.shedPacketCount += tallies.shedPacketCount
        counters.refusedOutboundBacklogPacketCount += tallies.refusedOutboundBacklogPacketCount
        counters.refusedInboundBacklogDatagramCount += tallies.refusedInboundBacklogDatagramCount
        counters.sendCompletionErrorCount += tallies.sendCompletionErrorCount
        counters.sendToPeerCount += tallies.sendToPeerCount
    }

    /// The engine's transport byte totals, delegated to the current session. `nil` when no session
    /// is current. `engineQueue.run` is re-entrant (`if isCurrent { work() }`), so the runner's own
    /// on-queue read runs inline here rather than deadlocking, and the `self.runner` read stays
    /// engine-queue-confined like every other access to it.
    public func snapshotStatistics() -> ChainedRunnerStatistics? {
        engineQueue.run { self.sampleStatisticsOnQueue() }
    }

    /// The prompt status read also reports runtime state when the runner is absent. No mutation,
    /// probing, persistence or recovery work is performed by this observation.
    public func snapshotStatusEvidence() -> ChainedDriverStatusEvidence {
        engineQueue.run {
            let stats = self.sampleStatisticsOnQueue()
            return ChainedDriverStatusEvidence(statistics: stats,
                verificationEpoch: self.verificationEpoch,
                forwardingBaseline: stats?.forwardingBaseline ?? 0,
                runtimeCondition: self.runtimeConditionOnQueue)
        }
    }

    private var runtimeConditionOnQueue: ChainedRuntimeCondition {
        if isRetired || hasSurrendered { return .retired }
        if isSuspended { return .suspended }
        if isOffline { return .offline }
        if isQuiesced || runner == nil || unavailableWakeBaselineSession == sessionGeneration || supervisor.isTimingAnOutage
            || rebindConfirmation != nil || settledPathRecovery != nil { return .recovering }
        return .normal
    }

    private func sampleStatisticsOnQueue() -> ChainedRunnerStatistics? {
        guard var stats = runner?.sampleStatistics() else { return nil }
        stats.sessionGeneration = sessionGeneration
        stats.verificationEpoch = verificationEpoch
        stats.runtimeCondition = runtimeConditionOnQueue
        if unavailableWakeBaselineSession == sessionGeneration {
            // This sentinel cannot produce a positive forwarding delta. Runtime remains recovering
            // until a valid boundary or replacement, rather than certifying an unknown wake tally.
            stats.forwardingBaseline = UInt64.max
        } else if let baseline = verificationForwardingBaseline,
           baseline.session == sessionGeneration, baseline.transport == stats.transportGeneration {
            stats.forwardingBaseline = baseline.bytes
        } else {
            // New runner/transport counters have their own zero origin. Never carry a wake
            // baseline onto a replacement channel or alter the runner's actual byte tally.
            stats.forwardingBaseline = 0
        }
        // Keep conservative first-setup admission. Pending demand is normal runtime state:
        // it withholds new setup proof but does not invalidate an app's witnessed milestone.
        let demand = runner?.snapshotCounters().unansweredDestinationCount ?? 0
        stats.setupReady = stats.hasHandshake && stats.transportGeneration == 1
            && !setupRequiresPostWakePeerEvidence && !isQuiesced && stats.runtimeCondition == .normal
            && demand == 0 && unansweredTunnelDNSNameKeys.isEmpty
        return stats
    }

    /// The rotation the LIVE runner was built from, or `0` when there is no runner.
    ///
    /// One engine-queue read of an immutable value, so "is a session running" and "which rotation
    /// is it running" are answered together and neither depends on the engine's statistics call
    /// succeeding.
    public func acceptedUpstreamGeneration() -> UInt64 {
        engineQueue.run { self.runner?.acceptedUpstreamGeneration ?? 0 }
    }

    /// Whether an outage is currently being timed. Diagnostics and tests only.
    public func isTimingAnOutage() -> Bool { engineQueue.run { self.supervisor.isTimingAnOutage } }

    /// Whether a surrender has been reported. Diagnostics and tests only.
    public func hasSurrenderedChaining() -> Bool { engineQueue.run { self.hasSurrendered } }

    // MARK: - Liveness

    /// Drains the runner's edge-triggered sample without ever discarding lifecycle proof.
    ///
    /// Sleep/wake and path recovery intentionally throw away OLD-path liveness credit before a
    /// socket transition. They still must report that the provider forwarded successfully at
    /// least once; otherwise those drains can erase the only proof before the regular tick sees it
    /// and repeated healthy provider replacements can falsely trip the startup-loop breaker.
    private func takeLivenessSampleReportingForwarding() -> ChainedLivenessSample {
        engineQueue.requireOnQueue()
        let sample = runner?.takeLivenessSample() ?? ChainedLivenessSample()
        if sample.sawInboundData {
            hasObservedHealthyForwarding = true
        }
        startHealthyForwardingReportIfNeeded()
        return sample
    }

    /// Starts at most one proof write. A failed async completion arms its own one-shot instead of
    /// waiting for another liveness sample: sleep and an unsatisfied path both cancel the repeating
    /// tick, but neither invalidates proof that this provider already forwarded real inbound data.
    /// pinned: ChainedOutageDriverTests.testTransientLifecycleProofFailureRetriesWhileTickIsSuspendedAndLatchesAfterSuccess
    private func startHealthyForwardingReportIfNeeded() {
        engineQueue.requireOnQueue()
        guard hasObservedHealthyForwarding, !didReportHealthyForwarding,
            !healthyForwardingReportIsInFlight, !isRetired, !hasSurrendered
        else { return }
        guard let onHealthyForwarding else {
            didReportHealthyForwarding = true
            return
        }
        healthyForwardingReportIsInFlight = true
        onHealthyForwarding { [weak self] proofBecameDurable in
            guard let self else { return }
            self.engineQueue.enqueue { [weak self] in
                guard let self else { return }
                self.healthyForwardingReportIsInFlight = false
                guard !self.isRetired, !self.hasSurrendered else { return }
                if proofBecameDurable {
                    self.didReportHealthyForwarding = true
                    self.healthyForwardingRetry?.cancel()
                    self.healthyForwardingRetry = nil
                } else {
                    self.scheduleHealthyForwardingRetry()
                }
            }
        }
    }

    private func scheduleHealthyForwardingRetry() {
        engineQueue.requireOnQueue()
        guard healthyForwardingRetry == nil, hasObservedHealthyForwarding,
            !didReportHealthyForwarding, !healthyForwardingReportIsInFlight,
            !isRetired, !hasSurrendered
        else { return }
        healthyForwardingRetry = armTimer(
            atSeconds: clock.nowSeconds() + Self.healthyForwardingProofRetrySeconds
        ) { [weak self] serial in
            self?.healthyForwardingRetryFired(serial: serial)
        }
    }

    private func healthyForwardingRetryFired(serial: UInt64) {
        engineQueue.requireOnQueue()
        guard healthyForwardingRetry?.serial == serial else { return }
        healthyForwardingRetry = nil
        startHealthyForwardingReportIfNeeded()
    }

    /// Decides, from data-path evidence alone, whether the tunnel is in an outage.
    ///
    /// Two conditions, and the conjunction is the point. Silence alone is an IDLE tunnel, which
    /// is not a fault; silence WHILE THE USER IS ASKING for something is the fault chained mode
    /// exists to bound. Recovery is the exact inverse — the next delivered inbound packet — which
    /// is what makes detection and recovery symmetrical rather than two unrelated predicates.
    ///
    /// Recovery deliberately does NOT consult the engine's handshake age. That value is session
    /// age rather than evidence of anything, so it is non-nil whenever a session slot is
    /// populated; a path that heals WITHOUT a rekey — a four-second blip, well inside the
    /// engine's own timers — would never end the outage, and the driver would surrender a tunnel
    /// that had been working for ten seconds. It is also denominated on the engine's continuous
    /// clock, which cannot be compared against this driver's uptime elapsed at all.
    /// pinned: ChainedOutageDriverTests.testInboundDataEndsAnOutageWithoutARekey
    private func sampleLiveness() {
        let now = clock.nowSeconds()
        let sample = takeLivenessSampleReportingForwarding()
        // The existing authenticated-peer bit includes a response to our forced handshake,
        // and excludes cookie replies/replayed initiations. It verifies setup, never forwarding.
        if sample.sawAuthenticatedPeerDatagram { setupRequiresPostWakePeerEvidence = false }
        if sample.sawInboundData {
            lastInboundDataAtSeconds = now
        }

        // SET FIRST, THEN CLEAR, and the order is load-bearing. Within one sample window there is
        // no way to order a send against an answer, so clearing last makes an ambiguous window
        // read as ANSWERED — the false-negative-leaning tie-break, costing at most one sample of
        // arming delay and only while the peer is answering, which is to say only while the link
        // works.
        // pinned: ChainedOutageDriverTests.testAnAmbiguousSampleReadsAsAnswered
        if sample.sawObligingSend, firstUnansweredSendAtSeconds == nil {
            firstUnansweredSendAtSeconds = now
        }
        if sample.sawAuthenticatedPeerDatagram || sample.sawInboundData {
            firstUnansweredSendAtSeconds = nil
            // A REBIND IS CONFIRMED BY EVIDENCE, not by the keepalive having been emitted. The
            // keepalive obliges the peer nothing, so emitting one proves only that the socket
            // accepted a write — which a black-holed socket also does.
            //
            // EITHER half of the recovery predicate confirms it, deliberately, and the weaker
            // half is not a loosening here: what has to be established is WHICH SOCKET carried
            // the traffic, and that is settled by the runner's generation check rather than by
            // the strength of the evidence. `sawInboundData` is the weaker signal for DETECTION,
            // where an unauthenticated sender must not be able to hold an outage open; a
            // datagram that decapsulated and reached the tunnel arrived on the new socket
            // whichever flag it set, and that is the whole question (Kilo, PR #493).
            // pinned: ChainedOutageDriverTests.testAConfirmedRebindDoesNotFallBackToARebuild
            // pinned: ChainedOutageDriverTests.testInboundDataAloneConfirmsARebind
            rebindConfirmation?.cancel()
            rebindConfirmation = nil
        }
        // ONE CONTINUOUS saturation, cleared the moment a sample shows the bound clear. A
        // latch would accumulate disjoint bursts of ordinary back-pressure into a phantom
        // threshold and tear down a link that is merely busy.
        // pinned: ChainedOutageDriverTests.testASaturationThatDrainsBeforeTheThresholdRestartsTheClock
        // The COUNT beside the clock is telemetry, not detection: sampled at tick cadence it
        // reads as wedge DURATION in the 60 s liveness delta, which is what separates a
        // sustained back-pressure stall from a burst that saturated and drained between ticks.
        if sample.sendChannelSaturated { counters.saturatedTickCount += 1 }
        channelSaturatedSinceSeconds = sample.sendChannelSaturated
            ? (channelSaturatedSinceSeconds ?? now)
            : nil

        // Egress-dead cause: a chain whose LINK answers every send but whose upstream forwards
        // nothing to the internet — the connect gate rejects it at establishment, but a server that
        // forwarded at connect and then lost its own upstream sails past that. The signal is
        // `forwardedNonDNSByteCount` (PR #558), a delivered-scope fact needing no probe; the demand
        // half is the user actively asking for general traffic. The window is anchored at demand
        // ONSET (like the silence arm) and requires SUSTAINED demand — any forwarding resets it, a
        // fresh session resets it, and a lapse in the asking resets it — so an idle chain, a
        // reconnecting one, and a one-shot packet never accumulate.
        let forwarding = sampleForwardingProgress()
        if forwarding.progressed {
            firstUnansweredNonDNSSendAtSeconds = nil
            lastObligingNonDNSSendAtSeconds = nil
        } else if sample.sawObligingNonDNSSend {
            lastObligingNonDNSSendAtSeconds = now
            if firstUnansweredNonDNSSendAtSeconds == nil {
                firstUnansweredNonDNSSendAtSeconds = now
            }
        } else if let last = lastObligingNonDNSSendAtSeconds,
            now - last >= Self.egressDeadDemandContinuitySeconds {
            // The user stopped asking; idle time is not a fault, so the window LAPSES rather than
            // counting toward the threshold.
            firstUnansweredNonDNSSendAtSeconds = nil
            lastObligingNonDNSSendAtSeconds = nil
        }

        if supervisor.isTimingAnOutage {
            // S6: link evidence ends an outage only when the tunnel-DNS cause does not hold
            // it — see `outageHeldByTunnelDNS` for why the alternative is an endless
            // kill-rebuild cycle. The guard carries the INVERSE claim of the observation
            // handler's: that handler ends a DNS-held outage itself on the served answer, so
            // the ordinary recovery never arrives here at all. What this branch owes is the
            // other direction — that a keepalive, or any datagram the peer happens to send,
            // cannot end an outage declared because the RESOLVER stopped answering.
            //
            // It is also the recovery for the one served-answer case the handler declines: an
            // answer that lands during the retry delay, with the runner already torn down,
            // releases the hold WITHOUT ending the outage. The ladder rebuilds, and the
            // replacement session's first inbound datagram ends it here.
            // pinned: ChainedOutageDriverTests.testLinkEvidenceDoesNotEndATunnelDNSOutage
            // pinned: ChainedOutageDriverTests.testAnAnswerDuringTheRetryDelayLeavesSomethingArmed
            if sample.sawAuthenticatedPeerDatagram || sample.sawInboundData,
                !outageHeldByTunnelDNS, !outageHeldByEgressDead {
                endOutage()
            }
            // Egress-dead recovery: ONLY real forwarding (a delivered non-DNS byte on the current
            // session) ends an egress-dead outage. A rebuilt session re-establishes the deceptive
            // link, so neither its handshake nor a mere new generation may end it — the upstream
            // must actually carry a byte, or the budget surrenders to DNS-only.
            // pinned: ChainedOutageDriverTests.testLinkEvidenceDoesNotEndAnEgressDeadOutage
            if forwarding.realForwarding, outageHeldByEgressDead {
                outageHeldByEgressDead = false
                endOutage()
            }
            return
        }

        let unanswered = firstUnansweredSendAtSeconds.map { now - $0 >= Self.linkSilenceThresholdSeconds }
            ?? false
        let wedged = channelSaturatedSinceSeconds.map { now - $0 >= Self.linkSilenceThresholdSeconds }
            ?? false
        if unanswered || wedged {
            beginOutage(atSeconds: now)
            return
        }

        // Egress-dead declaration: the user has been SUSTAINEDLY asking for general traffic —
        // measured from demand onset, reset on any lapse — and no byte has been forwarded for the
        // threshold. Bounded per lifetime because it keys on CHOSEN traffic (a user talking only to
        // an unresponsive destination could otherwise force a repeating surrender). The remediation
        // is surrender to DNS-only — a dead upstream is not fixed by rebuilding the chain, but the
        // user is served by falling back to the physical path with DNS still filtered.
        //
        // FULL TUNNEL ONLY. In a split tunnel the runner also carries the configured `AllowedIPs`
        // traffic, so `sawObligingNonDNSSend` fires on split user sends too; a send to a cached or
        // literal `AllowedIPs` address that is merely unresponsive then leaves the forwarding counter
        // flat on a HEALTHY chain, and no unrelated DNS reply is guaranteed inside the window to
        // reset it — so an unconditional predicate would false-surrender a working split tunnel. The
        // earlier note here leaned on "DNS-through-chain counts as forwarding" to prevent that, but
        // that only makes DNS replies COUNT; it does not make one OCCUR (Codex, PR #567). Gate the
        // cause on the routing shape instead. "The user asks for general traffic and nothing is
        // delivered" only unambiguously means dead egress when the tunnel is the default route.
        //
        // PORT-AWARE EXCLUSION (shared with the connect gate, PR #558; hardened as the PR #567
        // follow-up). `forwardedNonDNSByteCount` excludes an inbound byte only when it is an actual
        // DNS reply — source ADDRESS a configured resolver AND transport source port 53
        // (`ChainedSessionRunner` via `ChainedInboundDNSReply`), not by address alone. So a resolver
        // IP that ALSO serves ordinary traffic (e.g. 1.1.1.1 answers HTTPS) now contributes its
        // non-53 bytes as forwarding, and a user whose only non-DNS traffic is a sustained transfer
        // FROM that one resolver IP re-arms the count and does not false-surrender. The earlier
        // address-wide exclusion could, which is what the QA demand generator aimed exclusively at the
        // resolver IP surfaced on device 2026-08-23. RESIDUAL, fail-closed: a resolver IP reached only
        // over a portless protocol (ICMP) or only via fragmented non-DNS as the user's SOLE traffic
        // still reads as flat — the parser cannot prove those non-DNS from one packet, so it leaves
        // them excluded rather than risk the gate confirming over DNS-only forwarding. Narrower than
        // the address-wide edge it replaces, and in the direction that keeps the gate closed.
        // pinned: ChainedOutageDriverTests.testSustainedNonDNSDemandWithoutForwardingDeclaresAnOutage
        // pinned: ChainedOutageDriverTests.testAnIdleChainThatForwardsNothingIsNotAnOutage
        // pinned: ChainedOutageDriverTests.testIdleTimeBeforeDemandIsNotCountedTowardTheThreshold
        // pinned: ChainedOutageDriverTests.testAOneShotSendThenIdleNeverDeclares
        // pinned: ChainedOutageDriverTests.testASplitTunnelNeverDeclaresAnEgressDeadOutage
        if routingPolicy == .fullTunnel,
            let since = firstUnansweredNonDNSSendAtSeconds,
            now - since >= Self.egressDeadThresholdSeconds,
            egressDeadDeclarationCount < Self.maximumEgressDeadOutagesPerLifecycle {
            counters.egressDeadOutageCount += 1
            egressDeadDeclarationCount += 1
            outageHeldByEgressDead = true
            beginOutage(atSeconds: now)
        }
    }

    /// Reads the runner's delivered non-DNS byte total and reports whether general forwarding made
    /// progress this tick. `realForwarding` is a byte delivered on the CURRENT session — the only
    /// thing that ends an egress-dead outage. `progressed` also covers a fresh session (a new
    /// generation), which resets the detection clock but is NOT proof of forwarding: a rebuilt
    /// session must still deliver a byte before it can end an outage. Engine-queue confined, so the
    /// runner's own on-queue read runs inline.
    private func sampleForwardingProgress() -> (progressed: Bool, realForwarding: Bool) {
        guard let count = runner?.sampleStatistics()?.forwardedNonDNSByteCount else {
            return (false, false)
        }
        // A new session's byte total starts fresh (the generation bumps on adopt/rebuild), so
        // crossing the boundary resets the clock and only bytes it delivered ITSELF are forwarding.
        if sessionGeneration != lastForwardedGeneration {
            lastForwardedGeneration = sessionGeneration
            lastForwardedNonDNSByteCount = count
            return (true, count > 0)
        }
        if count > lastForwardedNonDNSByteCount {
            lastForwardedNonDNSByteCount = count
            return (true, true)
        }
        // A channel rebind resets the counter to zero WITHOUT bumping the generation (the WG
        // session persists); re-anchor without crediting it as forwarding progress.
        if count < lastForwardedNonDNSByteCount {
            lastForwardedNonDNSByteCount = count
        }
        return (false, false)
    }

    /// Resets the egress-dead DETECTION accumulation — its demand window — the way a paired wake and
    /// a path change reset the silence clock: demand and forwarding evidence gathered before the
    /// transition is stale. The byte baseline self-corrects in ``sampleForwardingProgress`` (a
    /// persisted session's next sample compares equal, a rebuilt one crosses the generation), so it
    /// is not touched here. The HOLD is NOT reset either; like the tunnel-DNS hold it belongs to the
    /// outage that opened it and survives a roam — a dead upstream is dead on either network.
    private func resetEgressDeadAccumulation() {
        firstUnansweredNonDNSSendAtSeconds = nil
        lastObligingNonDNSSendAtSeconds = nil
    }

    /// Clears the tunnel-DNS accumulation and RETIRES the window it belonged to.
    ///
    /// One function because the two must not be able to drift: a clear that forgets the
    /// epoch leaves observations already in flight able to seed the window that replaced
    /// theirs, which is the false-outage path (Codex, PR #513). Engine-queue confined; the
    /// lock is taken only to publish the new epoch to producers, never around anything that
    /// blocks.
    private func clearTunnelDNSAccumulationOnQueue() {
        engineQueue.requireOnQueue()
        firstUnansweredTunnelDNSAtSeconds = nil
        unansweredTunnelDNSNameKeys.removeAll()
        // Counted HERE, in the one function that retires, so the tally cannot drift from the
        // epoch it is counting. It is the observable for "exactly once per event" — a property
        // no test could otherwise assert without racing the few instructions between two
        // retirements on the same path (Codex, PR #513).
        counters.tunnelDNSWindowRetirementCount += 1
        // Taken from the ENGINE QUEUE, which is safe only because the producer side holds
        // this lock across nothing that can block — a clock read and an `async`. A clock
        // that could wait inside `reportTunnelDNSObservation` would deadlock this line.
        observationSubmission.lock()
        observationEpoch &+= 1
        observationSubmission.unlock()
    }

    private func endOutage() {
        guard let generation else { return }
        supervisor.endOutage(in: generation)
        self.generation = nil
        // The hold is per-outage state; whatever ends the outage retires it.
        outageHeldByTunnelDNS = false
        outageHeldByEgressDead = false
        // The ACCUMULATION goes with it, and the earlier version of this comment was wrong
        // about why it could stay: it claimed the answered observation had already cleared
        // it, which holds only on the served-answer path. An outage ended by LINK evidence
        // involves no observation at all, so a pre-outage failure timestamp survived with no
        // expiry — and one unanswered lookup minutes later, on a second name, then declared
        // instantly against a clock that started before the previous outage. The threshold
        // means "sustained NOW", so it measures from evidence this side of the last recovery.
        // pinned: ChainedOutageDriverTests.testAnOutageEndingClearsTheTunnelDNSAccumulation
        clearTunnelDNSAccumulationOnQueue()
        retireLiveAttempt()
        outageDeadline?.cancel()
        outageDeadline = nil
        retryDelay?.cancel()
        retryDelay = nil
        // Lifecycle proof belongs to the provider, not this outage generation; a pending retry
        // survives recovery and is canceled only by durable success or terminal teardown.
        pendingTicket = nil
        rescheduleTick()
        // The debt a coalesced in-outage flap left (C5). This path ends the outage on
        // EVIDENCE and keeps the runner, so no ladder attempt will ever bind the settled
        // path — and the confirming evidence can arrive through the old interface's brief
        // afterlife, leaving the session on the pre-transition socket until silence
        // detection (Codex, PR #504 round 2). The owed socket half runs now, outside the
        // outage: a rebind with its own confirmation window, or the ladder if no channel
        // can be built.
        if pendingSettledRecovery {
            pendingSettledRecovery = false
            performPathSocketRecovery(atSeconds: clock.nowSeconds())
        }
    }

    // MARK: - The outage

    /// Starts the clock, arms the budget, and SYNTHESIZES the session end that starts the ladder.
    ///
    /// The synthesis is not a convenience. `ChainedAttemptTicket` is minted at exactly one place
    /// — inside `ChainedOutageSupervisor.action`'s retry branch — which is reachable only with a
    /// non-nil session end. The watchdog path returns `carryOn` or `surrender` and nothing else.
    /// And because an authorized deadline is `now + remaining` while the policy guarantees a
    /// minimum useful window, the attempt deadline and the outage deadline are the SAME absolute
    /// instant, always — so every watchdog fire lands exactly at budget exhaustion, where the
    /// only answer is surrender.
    ///
    /// On a path that is simply dead the engine reports nothing for its full retransmit window,
    /// which is far longer than the budget. So without this the entire budget is `carryOn` and
    /// then surrender, with ZERO attempts made: the retry ladder, the backoff, the tickets and
    /// the receipts would never execute in production at all.
    ///
    /// `.reconnect(reason: .connectionExpired)` is not a forgery. It is what
    /// `ChainedDataPathPolicy` itself produces for that error, which is why
    /// `ChainedSessionEndCause`'s validating initialiser accepts it — the driver is reporting the
    /// same fact the engine will report much later, at the moment the data path already knows it.
    /// pinned: ChainedOutageDriverTests.testADeadPathReachesTheRetryLadderWithoutWaitingForTheEngine
    private func beginOutage(atSeconds now: Int) {
        startOutageClock(atSeconds: now)
        guard let cause = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return
        }
        // NAMED BY THE LAST RETIRED RECEIPT, not left receipt-less. The supervisor accepts a
        // receipt-less end only while nothing has ever been authorized, which is ONCE in its
        // lifetime — so a receipt-less synthesis fixed the first outage's ladder and left every
        // later one exactly as dead as before. The receipt of the attempt whose session is still
        // running is the name that identifies it, and the supervisor accepts it however old the
        // outage that issued it was.
        act(on: supervisor.action(atSeconds: now, endedBy: (cause, lastRetiredReceipt)))
    }

    /// Starts the clock and arms the budget, WITHOUT deciding anything about a session.
    ///
    /// Separated because two callers need it and only one of them synthesizes an end: a session
    /// that dies while no outage is being timed brings its own cause and must not have a
    /// fabricated one stacked on top of it.
    private func startOutageClock(atSeconds now: Int) {
        // Re-stored on EVERY call, not kept from the first. The supervisor advances its recovery
        // token on every `beginOutage` including the idempotent ones, and `endOutage` ignores a
        // token that is not the newest — so holding the first one means the outage can never be
        // ended.
        // COUNTED ONLY WHEN AN OUTAGE ACTUALLY BEGINS. The supervisor's start is idempotent —
        // a rebuild inside an outage already being timed re-enters here — but the counter was
        // not, so every path rebuild during one outage tallied another. That destroys the exact
        // diagnostic `offlinePathCount` was added for: an outage count that tracks the offline
        // count is supposed to mean a flapping DEVICE rather than a failing upstream, and a
        // counter inflated by the rebuilds themselves says that whatever is true
        // (Codex, PR #492).
        // pinned: ChainedOutageDriverTests.testRebuildingInsideAnOutageDoesNotCountASecondOne
        let wasAlreadyTiming = supervisor.isTimingAnOutage
        generation = supervisor.beginOutage(atSeconds: now)
        if !wasAlreadyTiming {
            counters.outageCount += 1
        }
        outageDeadline?.cancel()
        outageDeadline = armTimer(
            atSeconds: now + ChainedReconnectPolicy.maximumBlackholeSeconds
        ) { [weak self] serial in self?.outageDeadlineFired(serial: serial) }
        // THE REBIND CONFIRMATION DIES WITH THE SESSION IT WAS CONFIRMING. Once an outage is
        // being timed the ladder owns recovery, and a confirmation deadline armed for a session
        // this call is about to retire has nothing left to confirm. Left installed, it fires
        // mid-ladder and re-enters `beginOutage` — which retires whatever REPLACEMENT attempt is
        // live by then and advances the ladder a rung for a socket that was never given its
        // chance. Cancelled here rather than in `beginOutage` because a session that dies on its
        // own reaches this function WITHOUT going through it (Codex + Kilo, PR #493).
        // pinned: ChainedOutageDriverTests.testASessionDyingDuringTheConfirmationWindowDoesNotCostAnExtraRung
        rebindConfirmation?.cancel()
        rebindConfirmation = nil
        // The pending trailing recovery dies with the session era it was coalesced for, for
        // the same reason the confirmation above does: once an outage is being timed the
        // ladder owns recovery — its next attempt builds a fresh socket on the CURRENT path —
        // and a deferred rebuild firing mid-ladder would spend a rung on a socket the ladder
        // was about to build anyway.
        settledPathRecovery?.cancel()
        settledPathRecovery = nil
        retireLiveAttempt()
        absorbRunnerTallies()
        runner?.shutdown()
        runner = nil
        rescheduleTick()
    }

    private func outageDeadlineFired(serial: UInt64) {
        engineQueue.requireOnQueue()
        guard !hasSurrendered, supervisor.isTimingAnOutage,
              outageDeadline?.serial == serial
        else { return }
        act(on: supervisor.action(atSeconds: clock.nowSeconds(), endedBy: nil))
    }

    private func act(on action: ChainedOutageAction) {
        switch action {
        case .carryOn:
            break
        case .surrender(let reason):
            reportSurrender(reason)
        case .attempt(let afterSeconds, _, let ticket):
            pendingTicket = ticket
            retryDelay?.cancel()
            retryDelay = armTimer(atSeconds: clock.nowSeconds() + afterSeconds) { [weak self] serial in
                self?.startAuthorizedAttempt(serial: serial)
            }
        }
    }

    // MARK: - C1

    /// Authorizes an attempt and ARMS ITS WATCHDOG in one indivisible step.
    ///
    /// The ordering below is the whole discharge of `C1`, and every line of it is load-bearing:
    ///
    /// - ONE clock reading, used for the authorization and for the deadline. A second reading
    ///   between them would authorize against one instant and arm for another.
    /// - The ticket is spent BEFORE the supervisor is asked, so a re-entrant call cannot present
    ///   it twice whatever the supervisor answers.
    /// - The watchdog is armed and the live attempt recorded BEFORE the session is built.
    ///   Building can throw and the runner's initialiser can fail — both reachable, not
    ///   hypothetical — and arming afterwards would leave an authorized attempt with nothing
    ///   bounding it, with the supervisor's in-flight flag set and the receipt on the floor, so
    ///   every later authorization stands down forever.
    /// - The deadline is an ABSOLUTE instant from the clock, never `now + duration` computed at
    ///   the dispatch layer. `nowSeconds()` floors, so a relative arm lands in the next second,
    ///   where the remaining budget is already zero.
    /// pinned: ChainedOutageDriverTests.testTheWatchdogIsArmedAtTheAuthorizedInstantHoweverLateTheAttemptStarts
    /// pinned: ChainedOutageDriverTests.testAnAttemptIsAlreadyArmedWhenItsSessionBuildFails
    private func startAuthorizedAttempt(serial: UInt64) {
        engineQueue.requireOnQueue()
        guard !hasSurrendered, retryDelay?.serial == serial else { return }
        let now = clock.nowSeconds()
        guard let ticket = pendingTicket else { return }
        pendingTicket = nil

        switch supervisor.authorizeAttemptStartingNow(atSeconds: now, with: ticket) {
        case .standDown:
            counters.stoodDownCount += 1
            return
        case .refused(let reason):
            reportSurrender(reason)
            return
        case .authorized(let attempt, let deadlineAtSeconds, let receipt):
            let watchdog = armTimer(atSeconds: deadlineAtSeconds) { [weak self] serial in
                self?.watchdogFired(serial: serial)
            }
            live = LiveAttempt(
                attempt: attempt, deadlineAtSeconds: deadlineAtSeconds,
                receipt: receipt, watchdog: watchdog)
            counters.startedAttemptCount += 1
        }
        // ---- C1 discharged. Everything below may fail, throw, or never happen. ----

        let built: ChainedSessionDriving
        do {
            built = try source.makeSession(engineQueue: engineQueue, events: self)
        } catch {
            // THE ERROR IS CARRIED, not discarded. `try?` threw it away and reported
            // `.sessionCreationFailed` for every failure, which `ChainedReconnectPolicy` answers
            // with `.fallBackToDNSOnly(.engineUnusable)` — so one build refused because a handoff
            // had momentarily left no eligible interface ended chained mode for the rest of the
            // tunnel lifecycle, against a factory that documents that exact case as transient.
            //
            // `buildFailure` reads the factory's own diagnosis: a transient failure lands in
            // `finishAttempt` like any other session end and therefore spends a rung — the
            // attempt is retired and recorded, the outage clock is untouched, and the next
            // decision is made against the same budget. A permanent one still surrenders.
            // pinned: ChainedOutageDriverTests.testATransientBuildFailureSpendsARungRatherThanSurrendering
            finishAttempt(cause: .buildFailure(error), atSeconds: clock.nowSeconds())
            return
        }
        runner = built
        setupRequiresPostWakePeerEvidence = false
        verificationForwardingBaseline = nil
        unavailableWakeBaselineSession = nil
        sessionGeneration &+= 1  // rebuilt session: its byte totals start fresh (Codex, PR #554)
        // A fresh attempt's socket is bound to the path current NOW, so it satisfies any
        // socket recovery a coalesced in-outage flap left owed. Without this clear, the
        // first evidence on the new socket would end the outage and buy a redundant rebind
        // plus a confirmation window for a socket that is already the settled one.
        pendingSettledRecovery = false
        rescheduleTick()
        built.forceHandshake()
    }

    private func watchdogFired(serial: UInt64) {
        engineQueue.requireOnQueue()
        guard !hasSurrendered, let live, live.watchdog.serial == serial else { return }
        act(on: supervisor.action(atSeconds: clock.nowSeconds(), endedBy: nil))
    }

    /// The mirror of the C1 step, and equally indivisible.
    private func finishAttempt(cause: ChainedSessionEndCause, atSeconds now: Int) {
        engineQueue.requireOnQueue()
        counters.sessionEndCount += 1
        // A SESSION CAN DIE WITH NO OUTAGE IN PROGRESS — an idle rekey expiring, or the first
        // tick after a long sleep reporting `connectionExpired`. The supervisor guards `action`
        // on an active outage, so it would answer `.carryOn`; and by then this method has shut
        // the runner down and cancelled the tick, so no later liveness sample can start one
        // either. That is a permanent blackhole assembled out of two correct-looking pieces.
        // pinned: ChainedOutageDriverTests.testASessionDyingOutsideAnOutageStartsOne
        if !supervisor.isTimingAnOutage { startOutageClock(atSeconds: now) }
        // The watchdog is cancelled BEFORE the attempt is forgotten, always, in one body. A
        // retire that skips it leaves a timer that surrenders a healthy tunnel at the old
        // instant.
        retireLiveAttempt()
        absorbRunnerTallies()
        runner?.shutdown()
        runner = nil
        rescheduleTick()
        // NAMED BY `lastRetiredReceipt`, READ AFTER the retire — which is the same receipt this
        // attempt would have contributed, and the previous one when this end had no live
        // attempt of its own.
        //
        // Reading `live` here instead was a half-fix that looked whole. `startOutageClock`
        // retires the live attempt itself, so in the production shape — a session dying with no
        // outage running — `live` is ALWAYS nil by this line, and the end went to the supervisor
        // receipt-less. A receipt-less end is accepted only while nothing has ever been
        // authorized, once per supervisor LIFETIME, so after any earlier outage it was refused:
        // `.carryOn`, no attempt scheduled, and the budget ran out with the clock started and
        // nothing else happening. The started clock is what made it look handled.
        // pinned: ChainedOutageDriverTests.testASessionDyingOutsideAnOutageAfterAnEarlierOneStillAttempts
        act(on: supervisor.action(atSeconds: now, endedBy: (cause, lastRetiredReceipt)))
    }

    private func retireLiveAttempt() {
        guard let retired = live else { return }
        retired.watchdog.cancel()
        live = nil
        // REMEMBERED, not merely recorded. The session this attempt started usually outlives the
        // attempt — recovery retires the watchdog and keeps the runner — so a later outage's
        // synthesized end has to be able to name it.
        lastRetiredReceipt = retired.receipt
        supervisor.recordAttempt(retired.receipt)
    }

    private func reportSurrender(_ reason: ChainedReconnectPolicy.Surrender) {
        guard !hasSurrendered else { return }
        hasSurrendered = true
        live?.watchdog.cancel()
        live = nil
        outageDeadline?.cancel()
        outageDeadline = nil
        retryDelay?.cancel()
        retryDelay = nil
        healthyForwardingRetry?.cancel()
        healthyForwardingRetry = nil
        pendingTicket = nil
        absorbRunnerTallies()
        runner?.shutdown()
        runner = nil
        timers.scheduleTick(every: nil, leeway: .milliseconds(0))
        // Pass the counter snapshot with the reason so the sink can log WHICH arm surrendered in the
        // synchronous surrender event: this runs on the engine queue, so a `snapshotCounters()` hop
        // would deadlock, and a surrender that lands between the 60 s liveness polls would otherwise
        // carry only the generic reason (Codex, PR #567).
        surrender(reason, counters)
    }

    // MARK: - Timers

    /// Arms a one-shot timer and hands its OWN serial to the handler.
    ///
    /// The serial has to be captured at arming time, not read back when the timer fires. The
    /// first version's handler read `live?.watchdog.serial` at fire time and compared it against
    /// the live attempt — which is the same value by construction, so the check passed for every
    /// fire including a stale one. A guard that cannot fail is not a guard, and the whole point
    /// of the serial is that `DispatchSource.cancel()` does not retract a handler already
    /// delivered to the queue.
    private func armTimer(
        atSeconds seconds: Int,
        handler: @escaping @Sendable (UInt64) -> Void
    ) -> ChainedArmedTimer {
        nextSerial &+= 1
        let serial = nextSerial
        return timers.arm(at: clock.deadline(atSeconds: seconds), serial: serial) {
            handler(serial)
        }
    }

    /// The cadence is a pure function of driver state, re-scheduled only on a transition.
    ///
    /// An unconditional re-schedule would let a busy data path push the next fire out
    /// indefinitely. No runner means nothing to pump, so the tick is cancelled outright — before
    /// the first session, during a retry delay, after a surrender, and while suspended.
    /// pinned: ChainedOutageDriverTests.testTheTickRunsFastOnlyInsideAnOutageAndStopsWithoutARunner
    private func rescheduleTick() {
        // QUIESCED MEANS STAYS CANCELLED. `sleep()` and the unsatisfied path both cancel the
        // repeating tick deliberately, and this helper is called from paths that can run while
        // either latch is held — a satisfied-but-unchanged path update during a suspension was
        // enough to recreate the timer at 250 or 500 ms. `tick()` returns early, so nothing
        // DECIDES anything, but the extension still wakes its engine queue right through the
        // interval that was supposed to be quiet, which is a battery cost with no signal behind
        // it (Codex, PR #492).
        // pinned: ChainedOutageDriverTests.testAPathUpdateDuringSuspensionDoesNotResurrectTheTick
        guard !isQuiesced else {
            timers.scheduleTick(every: nil, leeway: .milliseconds(0))
            return
        }
        guard runner != nil, !hasSurrendered else {
            timers.scheduleTick(every: nil, leeway: .milliseconds(0))
            return
        }
        if supervisor.isTimingAnOutage {
            timers.scheduleTick(every: Self.outageTickInterval, leeway: Self.outageTickLeeway)
        } else {
            timers.scheduleTick(
                every: Self.establishedTickInterval, leeway: Self.establishedTickLeeway)
        }
    }
}

extension ChainedOutageDriver: ChainedSessionEvents {
    public func sessionEnded(_ cause: ChainedSessionEndCause) {
        // NOT DECIDED WHILE SUSPENDED, but the RUNNER IS RETIRED — and the second half was
        // missing when this guard was first written. Acting on the end would run
        // `finishAttempt`: a fresh deadline and retry armed into a suspending process, or an
        // immediate surrender the paired wake can never undo.
        //
        // Merely dropping the cause wedged the tunnel instead, because the runner has already
        // latched `hasEnded` by the time this is called. It stayed installed, so the wake saw
        // a non-nil runner and asked it to handshake — and `forceHandshake()` returns
        // immediately on an ended runner, as does every later `tick()`. My own comment here
        // claimed a dead runner would report its end again from that handshake; it does not,
        // and Codex caught the assertion I had not checked (PR #483).
        //
        // Retiring it makes the wake's nil-runner rule do the work: it starts a fresh outage,
        // which builds a new session and arms a new deadline.
        // pinned: ChainedOutageDriverTests.testASessionEndDeliveredAfterSleepBeganDecidesNothing
        // pinned: ChainedOutageDriverTests.testAWakeRebuildsARunnerThatEndedWhileSuspended
        guard !isQuiesced else {
            counters.sessionEndCount += 1
            absorbRunnerTallies()
            runner?.shutdown()
            runner = nil
            return
        }
        // QUEUED WITH ITS CAUSE, then drained by the outermost frame. The runner reaches this
        // from inside its own loops and from a transport that completes inline, so a re-entrant
        // delivery is ordinary rather than exceptional.
        pendingEnds.append(cause)
        guard !isProcessingEnd else { return }
        isProcessingEnd = true
        defer { isProcessingEnd = false }
        while !pendingEnds.isEmpty {
            let next = pendingEnds.removeFirst()
            finishAttempt(cause: next, atSeconds: clock.nowSeconds())
        }
    }
}
