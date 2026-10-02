import Foundation

/// Broad network-path categories recorded in tunnel health state.
public enum TunnelNetworkKind: String, Codable, Sendable {
    /// The current network kind is unavailable or has not been classified.
    case unknown
    /// The tunnel is using a Wi-Fi network path.
    case wifi
    /// The tunnel is using a cellular network path.
    case cellular
    /// The tunnel is using a wired network path.
    case wired
    /// The tunnel is using a known path outside the named categories.
    case other
}

/// A serializable snapshot of tunnel connectivity, resolver, and recovery health.
public struct TunnelHealthSnapshot: Codable, Equatable, Sendable {
    /// The time at which this health observation period began.
    public var startedAt: Date
    /// The time of the most recent snapshot update.
    public var updatedAt: Date
    /// The current broad network-path category.
    public var networkKind: TunnelNetworkKind
    /// The most recently recorded resolver address, if available.
    public var lastResolverAddress: String?
    /// The most recently recorded upstream failure reason label.
    public var lastFailureReason: String?
    /// The number of DNS cache hits recorded in this observation period.
    public var cacheHitCount: Int
    /// The number of DNS cache misses recorded in this observation period.
    public var cacheMissCount: Int
    /// The number of DNS queries combined with an in-flight equivalent query.
    public var coalescedQueryCount: Int
    /// The number of successful upstream resolutions recorded.
    public var upstreamSuccessCount: Int
    /// The number of failed upstream resolutions recorded.
    public var upstreamFailureCount: Int
    /// The current streak of consecutive upstream failures.
    public var consecutiveUpstreamFailureCount: Int
    /// The transport used for the most recently recorded resolver operation.
    public var lastResolverTransport: DNSResolverTransport
    /// The number of DNS-over-HTTPS HTTP failures recorded.
    public var dohHTTPFailureCount: Int
    /// ALPN id of the last successful DoH negotiation ("h3", "h2", "http/1.1").
    public var lastDoHHTTPVersion: String?
    /// The number of recorded upstream timeouts.
    public var upstreamTimeoutCount: Int
    /// The number of truncated UDP DNS responses recorded.
    public var udpTruncatedResponseCount: Int
    /// The number of TCP fallback attempts recorded.
    public var tcpFallbackAttemptCount: Int
    /// The number of successful TCP fallback attempts.
    public var tcpFallbackSuccessCount: Int
    /// The number of Device DNS fallback attempts.
    public var deviceDNSFallbackAttemptCount: Int
    /// The number of successful Device DNS fallback attempts.
    public var deviceDNSFallbackSuccessCount: Int
    /// The number of observations in which Device DNS was unavailable.
    public var deviceDNSUnavailableCount: Int
    /// Whether the most recently observed network path was satisfied.
    public var networkPathIsSatisfied: Bool
    /// The time of the most recent DNS smoke probe, if one has run.
    public var lastDNSSmokeProbeAt: Date?
    /// The outcome of the most recent DNS smoke probe, if one has run.
    public var lastDNSSmokeProbeSucceeded: Bool?
    /// The number of successful DNS smoke probes recorded.
    public var dnsSmokeProbeSuccessCount: Int
    /// The number of failed DNS smoke probes recorded.
    public var dnsSmokeProbeFailureCount: Int
    /// Consecutive failed DNS smoke probes, reset only by a smoke-probe success.
    /// Unlike `consecutiveUpstreamFailureCount` this is NOT reset by forwarding /
    /// encrypted-fallback successes or self-reconnects, so a primary resolver that
    /// keeps failing its health probe can't be masked "healthy" by incidental
    /// fallback-carried traffic — the signal the connectivity policy escalates on.
    public var consecutiveDNSSmokeProbeFailureCount: Int
    /// Consecutive smoke probes that returned a REACHABLE-but-rejected answer
    /// (`rejected-response`) from the SAME resolver identity. Unlike
    /// `consecutiveDNSSmokeProbeFailureCount` this is resolver-identity-scoped and is
    /// deliberately kept OUT of every recovery reset path — network-change recovery, the
    /// device-DNS settle/recapture churn, wake, AND the organic forwarding path (where a
    /// REFUSED reply counts as `didResolve`). It is cleared only by an accepted primary
    /// smoke-probe success or a resolver change. A churny roaming network kept the generic streak
    /// pinned under the reconnect threshold so a steadily hijacking/stale resolver never
    /// escalated (UR-37 / LAV-87); this survives that churn so recovery can engage.
    public var consecutiveRejectedSmokeResponseCount: Int
    /// The resolver identity (`primaryCacheIdentifier` — the primary alone, without the
    /// fallback components that churn on handoff) the rejected-response streak is counting,
    /// so a handoff to a different resolver restarts the count instead of carrying it over.
    public var rejectedSmokeResponseResolverIdentity: String?
    /// Times the rejected-response streak was re-keyed to a different resolver identity this
    /// session. QA instrument for the identity scoping: during a steady-hijacker replay this
    /// stays frozen while the streak climbs to the escalation threshold.
    public var rejectedSmokeResponseRescopeCount: Int
    /// Whether Device DNS fallback mode is currently active.
    public var deviceDNSFallbackModeActive: Bool
    /// The most recent time Device DNS fallback mode was activated.
    public var lastDeviceDNSFallbackActivatedAt: Date?
    /// The number of Device DNS fallback mode activations recorded.
    public var deviceDNSFallbackActivationCount: Int
    /// Resolution attempt counts keyed by resolver address.
    public var resolverAttemptCounts: [String: Int]
    /// Successful resolution counts keyed by resolver address.
    public var resolverSuccessCounts: [String: Int]
    /// Failed resolution counts keyed by resolver address.
    public var resolverFailureCounts: [String: Int]
    /// The time of the most recently recorded network change.
    public var lastNetworkChangeAt: Date?
    /// The number of network changes recorded.
    public var networkChangeCount: Int
    /// The time of the most recent resolver runtime reset.
    public var lastResolverRuntimeResetAt: Date?
    /// The reason label for the most recent resolver runtime reset.
    public var lastResolverRuntimeResetReason: String?
    /// The instant the configured resolver IDENTITY actually changed (a different upstream),
    /// distinct from `lastResolverRuntimeResetAt`, which is also bumped by same-resolver runtime
    /// resets (snapshot reloads, pause/resume, recovery). Only a genuine identity change is a fresh
    /// DNS-health context, so this — not the broad reset timestamp — anchors the smoke-probe /
    /// encrypted-fallback coverage baseline.
    public var lastResolverIdentityChangeAt: Date?
    /// The number of resolver runtime resets recorded.
    public var resolverRuntimeResetCount: Int
    /// The time of the most recent successful upstream resolution on any path.
    public var lastUpstreamSuccessAt: Date?
    /// Timestamp of the last forwarding success carried by the configured PRIMARY
    /// upstream (i.e. not the encrypted Device-DNS safety net). The silent recovery
    /// banner-clear keys off this rather than `lastUpstreamSuccessAt` so a query
    /// that only resolved because the encrypted fallback caught it does not clear
    /// the "reconnect" banner while the primary remains wedged and traffic still
    /// depends on the safety net.
    public var lastPrimaryUpstreamSuccessAt: Date?
    /// Timestamp of the last DNS forwarding success carried by the ENCRYPTED safety net
    /// (the DoH/DoT fallback for a device-DNS-primary config). Set ONLY when a query
    /// resolved via that encrypted fallback. The connectivity policy reads this to
    /// recognise the encrypted fallback is actively serving DNS, so a transition-induced
    /// primary-resolver staleness does not warrant a user-visible self-reconnect. Kept
    /// deliberately SEPARATE from `lastPrimaryUpstreamSuccessAt` (never set in the same
    /// branch) so fallback-carried traffic can't paint the wedged primary "healthy".
    public var lastEncryptedFallbackSuccessAt: Date?
    /// The time of the most recent failed upstream resolution.
    public var lastUpstreamFailureAt: Date?
    /// The duration, in milliseconds, of the most recently timed upstream operation.
    /// Set for failures/timeouts too, so this is a raw "what just happened" value — the
    /// user-facing "Last DNS response" row uses `lastUpstreamSuccessDurationMilliseconds`.
    public var lastUpstreamDurationMilliseconds: Int?
    /// The round-trip duration, in milliseconds, of the most recent *successful* upstream
    /// resolution. Distinct from `lastUpstreamDurationMilliseconds` so the "Last DNS
    /// response" row never reports a timeout's duration as a response (LAV-119).
    public var lastUpstreamSuccessDurationMilliseconds: Int?
    /// Session-cumulative histogram of upstream round-trip durations, backing the Nerd
    /// Stats p50/p90/p95 rows (plans/2026-07-11-nerd-stats-dns-latency-plan.md).
    public var upstreamLatencyHistogram: DNSLatencyHistogram
    /// The number of upstream responses classified as slow.
    public var slowUpstreamResponseCount: Int
    /// The current streak of upstream responses classified as slow.
    public var consecutiveSlowUpstreamResponseCount: Int
    /// The time of the most recent upstream response classified as slow.
    public var lastSlowUpstreamResponseAt: Date?
    /// The time of the most recent network-settings reapply failure.
    public var lastNetworkSettingsReapplyFailureAt: Date?
    /// The reason label for the most recent network-settings reapply failure.
    public var lastNetworkSettingsReapplyFailureReason: String?
    /// The number of network-settings reapply failures recorded.
    public var networkSettingsReapplyFailureCount: Int
    /// Queries served fail-closed (`.protectionUnavailable`) this session. Deliberately kept
    /// OUT of user-facing filtering counts and Domain History (a fail-closed block is not a
    /// blocklist match — #164 honesty rule); without a health-side trace, a past fail-closed
    /// window is indistinguishable from "no incident" in a field report.
    public var failClosedServedQueryCount: Int
    /// The most recent time a query was served fail-closed.
    public var lastFailClosedAt: Date?
    /// "snapshot-unavailable" (no usable snapshot could be loaded/compiled — a restart cannot
    /// fix it) vs "transient-protection-unavailable" (e.g. the cold-start bootstrap window
    /// while the real snapshot decodes).
    public var lastFailClosedReason: String?
    /// Queries the filter pipeline classified as BLOCKED (real blocklist matches, never
    /// fail-closed serves) while this boot session's shared diagnostics stores still
    /// reflected a locked boot — i.e. inside the reboot-before-first-unlock window. The
    /// health snapshot is control-plane state (`NSFileProtectionNone`, INV-PERSIST-2) and
    /// is never reloaded mid-session, so these counters survive to a post-unlock export
    /// as the QA release gate's DIRECT locked-window filtering evidence — the Class-C
    /// privacy stores legitimately defer or drop their locked-window rows (incident plan
    /// Phase 4 follow-up; lavasec-infra
    /// `docs/engineering/reboot-first-unlock-qa-protocol.md`, "Path A").
    public var lockedBootBlockedQueryCount: Int
    /// Queries classified as ALLOWED inside the locked-boot window (includes
    /// `.pausedAllow` pass-throughs — the gate runs with protection ON, so those should
    /// not occur in a gate pass). Allowed-only with zero blocked against seeded
    /// blocked-domain traffic is how the gate distinguishes a pass-through regression
    /// from real filtering; see `lockedBootBlockedQueryCount`.
    public var lockedBootAllowedQueryCount: Int
    /// Queries served fail-closed inside the locked-boot window (the session-wide
    /// sibling is `failClosedServedQueryCount`); see `lockedBootBlockedQueryCount`.
    public var lockedBootFailClosedQueryCount: Int
    /// The conservative END boundary of this boot session's locked window: the LAST
    /// instant the shared protected content was actually OBSERVED locked, stamped at the
    /// first readable reload. Deliberately not the reload's own wall clock — the reload
    /// runs one flush latency after the real unlock, and a boundary of "reload time"
    /// would admit post-unlock decisions made in that gap as boot evidence, letting a
    /// post-unlock blocked query falsely satisfy the QA gate (Codex review, #381).
    /// Bounding at the last observation under-counts the (observation, unlock] sliver
    /// instead — the gate may under-report and rerun, never fabricate. nil means the
    /// session never observed a locked window end: either it started unlocked (normal
    /// launch — the lockedBoot* counters stay 0 and carry no meaning) or the device was
    /// never unlocked before the process died. Non-nil with zero counters means a locked
    /// window existed but carried no classified traffic.
    public var lockedBootWindowEndedAt: Date?

    // MARK: Chained-upstream health (Slice 3)
    //
    // The user-facing DNS-health surfaces read these instead of the physical counters above when
    // `isChainedUpstreamActive` is true, because while chained the physical resolver is not the
    // path in use and its counters stay stale. Source: `ChainedOutageDriver.snapshotCounters()`.
    //
    // `isChainedUpstreamActive` is false in DNS-only mode (and is cleared on stop); the COUNTERS
    // are not zeroed there — they retain the last chained session's final values, which is
    // harmless because the surfaces hide them while the flag is false, and the flag disambiguates
    // them anywhere the whole snapshot is read (a bug report).

    /// Whether the tunnel is running the chained WireGuard upstream data path right now. This is
    /// the RUNTIME latch, not the configured preference — the app's `chainedUpstreamEnabled`
    /// reflects intent, only the provider knows the live latch — so it is the honest signal the
    /// health surfaces switch on.
    public var isChainedUpstreamActive: Bool
    /// Tunnelled DNS resolutions reported answered (a valid response, TC included) while chained.
    public var chainedTunnelDNSAnsweredCount: Int
    /// Tunnelled DNS resolutions sent and left unanswered while chained.
    public var chainedTunnelDNSUnansweredCount: Int
    /// Times the chained outage supervisor declared a tunnel-DNS outage (surrendered to dns-only).
    public var chainedTunnelDNSOutageCount: Int
    /// Times the chained tunnel's network path went offline (link connectivity lost) — distinct
    /// from a DNS-answer outage (`chainedTunnelDNSOutageCount`, itself a subset of the driver's
    /// total outage count), so link liveness is not conflated with a resolver that stopped
    /// answering. There is no matching "recovered from offline" counter to pair it with — the
    /// driver's `pathRecoveryCount` also counts routine interface handoffs — so none is surfaced.
    public var chainedLinkOutageCount: Int

    /// In-tunnel destinations under sustained demand with nothing coming back, and the longest such
    /// wait in seconds — the per-destination reachability reading
    /// (`ChainedDestinationReachabilityPolicy`). Zero and zero is the healthy reading.
    ///
    /// THE SIGNAL A SPLIT-TUNNEL CHAIN HAD NO WAY TO PRODUCE, and every other field here reads
    /// healthy in the case it catches. In the 2026-08-27 capture the chain had a handshake, zero
    /// outages, and `forwardedNonDNSByteCount` equal to `receivedByteCount` to the byte — because
    /// in split tunnel the resolver sits inside the claimed range and its replies land in that
    /// counter (PR #558) — while the one host the user wanted answered nothing.
    ///
    /// A DURATION AND A COUNT, NEVER AN ADDRESS. This snapshot reaches a bug report, and a tailnet
    /// address names the user's network as surely as a resolver address does — the lesson
    /// `redactingChainedFallbackAddresses()` exists for (PR #575, PR #592). Keeping addresses out
    /// entirely means there is nothing here for that fold to reach, and no further road into a
    /// report.
    public var chainedUnansweredDestinationCount: Int
    /// The longest current unanswered wait in seconds, or zero when no destination is unanswered.
    public var chainedLongestUnansweredDestinationSeconds: Int

    /// The chained data path's transmit/receive plaintext byte volume over the last focus-tick
    /// window (~60 s), sampled from the WireGuard engine while chained. Surface-only telemetry: a
    /// window where transmit far outruns receive is a peer that stays reachable but stops forwarding
    /// replies (see `DataPathHealth`), but nothing acts on it. Both are 0 in DNS-only mode and
    /// before the first full window (no prior sample to difference against).
    public var chainedDataPathTransmitWindowBytes: UInt64
    public var chainedDataPathReceiveWindowBytes: UInt64
    /// Whether the chained engine had an established session at the last sample — byte deltas are
    /// only forwarding evidence while true.
    public var chainedDataPathHasHandshake: Bool

    // The T1 DNS fallback's observed state, so the settings surface can say whether it is
    // actually doing anything instead of only that it is switched on. See
    // ``ChainedFallbackStatus`` for the two invisible failures these distinguish and why neither
    // is derivable from configuration alone.
    //
    // COUNTS AND FLAGS, never the resolver ADDRESS. The address is already the app's own setting,
    // so carrying it here would be a second source for one fact — and this snapshot reaches bug
    // reports, where a private internal resolver (`10.x`) is a detail about the user's network
    // that the status does not need.

    /// Whether a chained session has actually evaluated the fallback selection. False before the
    /// first chained start and in DNS-only mode — without it, "enabled but idle" and "never
    /// checked" are the same all-zero reading.
    public var chainedFallbackEvaluated: Bool
    /// The fallback addresses the live chained session LATCHED — the raw selection as it stood at
    /// session start, in the user's own terms.
    ///
    /// Its only job is the staleness comparison. The provider keeps this latch for the session's
    /// life, so a mid-session change leaves every counter below describing the OLD selection:
    /// enabling from an off session could label a fresh address unusable on the previous latch's
    /// verdict, and switching providers could credit the new one with the old one's rescues
    /// (Codex, PR #575). The app compares this against its own current selection — the same raw
    /// list, so the comparison is exact — and reports "awaiting restart" rather than showing one
    /// resolver's evidence under another's name.
    ///
    /// The RAW list rather than the effective one, deliberately: the effective set is a subset
    /// after the gates and the T0 dedup, so comparing it against the user's selection would
    /// read as stale forever.
    public var chainedFallbackLatchedAddresses: [String]
    /// A TRANSPORT-AWARE identity for the T1 selection this session latched
    /// (`AppConfiguration.chainedTierOneResolverIdentity`), or empty before one is published.
    ///
    /// THE FRESHNESS COMPARISON READS THIS, not the addresses beside it. Endpoints alone cannot
    /// tell one transport of a provider from another whenever both reach the same host, so the
    /// panel reported "current" for a session running the other one — the collision the coerced
    /// `plainDNSVariant` array made unavoidable and this replaces (the plan's S4 obligation).
    ///
    /// REDACTED FROM BUG REPORTS by ``redactingChainedFallbackAddresses()``, in full: a Custom
    /// entry puts the user's own resolver address or DoH URL inside this string, which is exactly
    /// the disclosure the addresses beside it are cleared for.
    public var chainedFallbackLatchedIdentity: String
    /// The identifiers a T1 attempt is RECORDED under — `AppConfiguration.chainedTierOneResolverAttemptKeys`
    /// — which is what keys ``resolverAttemptCounts`` and its siblings.
    ///
    /// SEPARATE FROM ``chainedFallbackLatchedAddresses``, because for an encrypted selection the
    /// two genuinely differ: the latched list carries the endpoint's HOST so the panel can name it,
    /// while `ResolverOrchestrator.resolveEndpoints` records under the endpoint's `cacheIdentifier`
    /// — the complete `doh:<absolute URL>`. ``redactingChainedFallbackAddresses()`` folds resolver
    /// counters onto placeholders by matching those keys, so a host-only map matched nothing and a
    /// Custom DoH endpoint travelled into the report intact (Codex P1, PR #591).
    ///
    /// Identical to the latched list for a plain selection, which is why this was invisible until
    /// an encrypted resolver could become the rung.
    public var chainedFallbackAttemptKeys: [String]
    /// `ChainedUpstreamConfiguration.resolverSelectionFingerprint` for the configuration THIS
    /// session latched.
    ///
    /// The fallback addresses are only half of "does the live session match the settings":
    /// admission also depends on the upstream's `AllowedIPs`, `DNS =` and client address, so
    /// replacing a full-tunnel configuration with a split one reverses the verdict while leaving
    /// the chosen resolver untouched. Empty when no chained session has published one
    /// (Codex, PR #575).
    public var chainedFallbackLatchedConfigurationFingerprint: String
    /// The stored-upstream GENERATION this session latched its chained data path against, or
    /// `0` when no chained upstream is latched.
    ///
    /// WHY A SECOND IDENTITY, beside the fingerprint above. That one is
    /// `resolverSelectionFingerprint` — `AllowedIPs`, the conf's `DNS =`, the client address —
    /// so it answers "would admission decide differently". It deliberately does NOT move when a
    /// rotation replaces only the endpoint and the keys, which is the common rotation and the
    /// one whose staleness the user feels: the session keeps handshaking against a peer the
    /// stored configuration no longer names, and every surface reports agreement.
    ///
    /// So the two are not redundant and neither subsumes the other: the fingerprint answers
    /// "is the SELECTION still the one in effect", this answers "is the ROTATION still the one
    /// in effect". A stale session moves this and leaves that untouched.
    ///
    /// `0` IS "NONE OR UNKNOWN", never "generation zero" — a DNS-only latch publishes it, as
    /// does a session that predates this field in a decoded snapshot. Consumers must treat it
    /// as no answer rather than as disagreement, or a freshness panel appears on every
    /// DNS-only session claiming a change nobody made.
    ///
    /// AN OPAQUE IDENTITY, NOT A COUNTER, and consumers must compare it rather than order it.
    /// `ChainedUpstreamGenerationMint.mint` draws eight random bytes and excludes only `0` and
    /// the currently committed value, so the next rotation is routinely numerically LOWER than
    /// the one it replaces. Anything that reasoned "newer means greater" would call a fresh
    /// rotation stale roughly half the time (Codex P3, PR #613).
    ///
    /// `0` is a safe sentinel precisely because the mint refuses to draw it.
    ///
    /// SAFE IN A BUG REPORT, unlike most of this neighbourhood: an opaque identifier naming a
    /// rotation discloses no key, endpoint or address, so `redactingChainedFallbackAddresses()`
    /// leaves it alone on purpose.
    /// pinned: TunnelHealthSnapshotTests.testTheLatchedUpstreamGenerationSurvivesRedaction
    public var runningChainedUpstreamGeneration: UInt64
    /// The fallback addresses actually IN EFFECT — the T1 set that passed every gate and was
    /// appended to the resolver route. Empty means none was usable.
    ///
    /// This, not the raw latch, is what the counters below aggregate, so it is what the surface
    /// must NAME. A built-in provider contributes two IPv4 servers (Cloudflare, Google, Quad9),
    /// and attributing the pair's aggregate evidence to `.first` reported the wrong address
    /// whenever the second one served — and could name a T0 address outright when the first
    /// overlaps the configuration's own `DNS =` and is deduped out of the appended set
    /// (Codex, PR #575).
    ///
    /// Every member is inside the configuration's own `AllowedIPs` — the coverage gate in
    /// `ChainedTunnelResolverSelection` is what admits an address here — so what the panel names
    /// and what the data path accepts are the same list, with no carve-out involved. A carve-out
    /// was tried and reverted: accepting an off-route reply never made its query routable
    /// (Codex, PR #575).
    public var chainedFallbackEffectiveAddresses: [String]
    /// T1 addresses this session HAS asked but is no longer asking — the ones a moved capture
    /// retired — kept for one reason only: the bug report's redaction fold.
    ///
    /// WHY THIS FIELD EXISTS. A device-DNS rung's addresses are the tunnel's live capture, so a
    /// roam replaces them, and `publishChainedFallbackOutcomesOnQueue` republishes the new set
    /// over the old one. But `resolverAttemptCounts` and its siblings are SESSION-WIDE and keyed
    /// by the address that was tried, so the retired resolver stays in them — while
    /// ``redactedFallbackIdentities()`` builds its folding map from the CURRENT lists alone. The
    /// old address therefore survived into a report as a verbatim dictionary key: a LAN or ISP
    /// resolver naming the user's network, which is exactly the disclosure the lists beside it
    /// are cleared for (Codex P1, PR #592).
    ///
    /// It could not be fixed by folding the counter maps at the moment of the roam. They are
    /// owned by `ResolverHealthEvidence`'s session state and PROJECTED into this snapshot, so a
    /// write here is overwritten by the next projection; the source of truth is in LavaSecDNS and
    /// deleting live evidence from it to satisfy a reporting concern is the wrong trade.
    ///
    /// ADDRESSES *AND* ATTEMPT KEYS, despite the name. An encrypted attempt is recorded under the
    /// endpoint's `cacheIdentifier` (`doh:https://host/path`) while the latched list carries only
    /// the host, so a Custom DoH URL that changes its path keeps the same host on both sides of a
    /// relatch — the address lists never move — while the old full URL is dropped from
    /// ``chainedFallbackAttemptKeys`` and left keying the counter maps, reaching a report verbatim
    /// (Codex P1, PR #592, second round). One list serves both because both are KEYS OF THE SAME
    /// MAPS and both fold to the same T1 placeholder; the name is kept so archived reports
    /// keep decoding.
    ///
    /// UNBOUNDED BY DESIGN, and that is not an oversight. It has to cover every key still present
    /// in the counter maps, so any cap below their size re-opens the leak for whatever it dropped.
    /// It grows in lockstep with the distinct resolvers one session has actually asked, which is
    /// what those maps hold too — the same bound, not a new one. Entries are unique.
    ///
    /// NOT A PANEL FIELD. The settings surface names the CURRENT resolvers; this is retired
    /// history and no UI reads it. Cleared outright by ``redactingChainedFallbackAddresses()``,
    /// like every other address list here.
    public var chainedFallbackRetiredAddresses: [String]
    /// What became of EACH chosen fallback address, in the order the user chose them.
    ///
    /// Replaces the summary booleans this used to carry. The addresses can meet different fates
    /// in one session — one deduped into T0, another refused by a gate — and any single claim
    /// about the set is wrong for some arrangement of them, which is the defect four consecutive
    /// review rounds re-found in new clothes (see ``ChainedFallbackDisposition``). Carrying the
    /// per-address facts lets the surface enumerate instead of assert.
    public var chainedFallbackOutcomes: [ChainedFallbackAddressOutcome]
    /// Consecutive fallback REPLIES that did not serve the name — SERVFAIL, REFUSED, truncated —
    /// reset by a rescue.
    ///
    /// The sibling of ``chainedFallbackUnansweredStreak``, and needed because that one resets on
    /// ANY answer, soft failures included. A fallback that serves one lookup and then soft-fails
    /// every retry keeps clearing the unanswered streak while its cumulative rescue count stays
    /// positive, so it read `working` forever and `answeringWithoutResolving` could never surface
    /// (Codex, PR #575). Two streaks, because "replied" and "helped" are different questions.
    ///
    /// Counts REPLIES rather than attempts, so it is also the honest payload for that state: a
    /// lifetime answer total includes the rescues, and reporting it made the copy say four retries
    /// could not resolve the name when one of them had. A silence does not reset it — a timeout is
    /// not a reply, and forgetting the run because one datagram vanished would hide a resolver
    /// that is steadily declining.
    public var chainedFallbackUnhelpfulReplyStreak: Int
    /// Fallback attempts since the last answer of ANY kind, reset by each answer.
    ///
    /// One of the two fallback terms that can FALL, alongside
    /// ``chainedFallbackUnhelpfulReplyStreak``. Every COUNT here is cumulative for the session, so
    /// once a rescue lands they can only ever make the fallback look healthier — a resolver that
    /// served one lookup and then went dark (the exit node's forwarding changing mid-session)
    /// would read `working` for the rest of the session. The falling terms are what let a present
    /// failure overrule a past success (Codex, PR #575).
    ///
    /// This one answers "is anything coming back at all"; its sibling answers "is what comes back
    /// helping". Both are needed because an answer that does not resolve the name resets THIS one
    /// while leaving the fallback just as useless.
    public var chainedFallbackUnansweredStreak: Int
    /// Times an admitted fallback address was actually queried (the primary failed over to it).
    public var chainedFallbackAttemptCount: Int
    /// Times an admitted fallback address REPLIED — with anything valid, SERVFAIL/REFUSED and a
    /// truncated answer included. A reply proves the peer forwarded and the resolver is
    /// reachable, which is what separates "couldn't resolve it either" from "nothing is coming
    /// back at all"; attempts alone cannot (Codex, PR #575).
    public var chainedFallbackAnswerCount: Int
    /// Times an admitted fallback address SERVED an answer the client received — the subset of
    /// attempts that worked. Attempts without rescues is the peer-not-forwarding signature.
    public var chainedFallbackRescueCount: Int
    /// Independent, privacy-safe observations and repair status for the canonical DNS tiers.
    public var dnsTierHealth: [DNSResolverTierHealthSnapshot]

    private enum CodingKeys: String, CodingKey {
        case startedAt
        case updatedAt
        case networkKind
        case lastResolverAddress
        case lastFailureReason
        case cacheHitCount
        case cacheMissCount
        case coalescedQueryCount
        case upstreamSuccessCount
        case upstreamFailureCount
        case consecutiveUpstreamFailureCount
        case lastResolverTransport
        case dohHTTPFailureCount
        case lastDoHHTTPVersion
        case upstreamTimeoutCount
        case udpTruncatedResponseCount
        case tcpFallbackAttemptCount
        case tcpFallbackSuccessCount
        case deviceDNSFallbackAttemptCount
        case deviceDNSFallbackSuccessCount
        case deviceDNSUnavailableCount
        case networkPathIsSatisfied
        case lastDNSSmokeProbeAt
        case lastDNSSmokeProbeSucceeded
        case dnsSmokeProbeSuccessCount
        case dnsSmokeProbeFailureCount
        case consecutiveDNSSmokeProbeFailureCount
        case consecutiveRejectedSmokeResponseCount
        case rejectedSmokeResponseResolverIdentity
        case rejectedSmokeResponseRescopeCount
        case deviceDNSFallbackModeActive
        case lastDeviceDNSFallbackActivatedAt
        case deviceDNSFallbackActivationCount
        case resolverAttemptCounts
        case resolverSuccessCounts
        case resolverFailureCounts
        case lastNetworkChangeAt
        case networkChangeCount
        case lastResolverRuntimeResetAt
        case lastResolverRuntimeResetReason
        case lastResolverIdentityChangeAt
        case resolverRuntimeResetCount
        case lastUpstreamSuccessAt
        case lastPrimaryUpstreamSuccessAt
        case lastEncryptedFallbackSuccessAt
        case lastUpstreamFailureAt
        case lastUpstreamDurationMilliseconds
        case lastUpstreamSuccessDurationMilliseconds
        case upstreamLatencyHistogram
        case slowUpstreamResponseCount
        case consecutiveSlowUpstreamResponseCount
        case lastSlowUpstreamResponseAt
        case lastNetworkSettingsReapplyFailureAt
        case lastNetworkSettingsReapplyFailureReason
        case networkSettingsReapplyFailureCount
        case failClosedServedQueryCount
        case lastFailClosedAt
        case lastFailClosedReason
        case lockedBootBlockedQueryCount
        case lockedBootAllowedQueryCount
        case lockedBootFailClosedQueryCount
        case lockedBootWindowEndedAt
        case isChainedUpstreamActive
        case chainedTunnelDNSAnsweredCount
        case chainedTunnelDNSUnansweredCount
        case chainedTunnelDNSOutageCount
        case chainedLinkOutageCount
        case chainedUnansweredDestinationCount
        case chainedLongestUnansweredDestinationSeconds
        case chainedDataPathTransmitWindowBytes
        case chainedDataPathReceiveWindowBytes
        case chainedDataPathHasHandshake
        case chainedFallbackEvaluated
        case chainedFallbackLatchedAddresses
        case chainedFallbackLatchedIdentity
        case chainedFallbackAttemptKeys
        case chainedFallbackLatchedConfigurationFingerprint
        case runningChainedUpstreamGeneration
        case chainedFallbackEffectiveAddresses
        case chainedFallbackRetiredAddresses
        case chainedFallbackOutcomes
        case chainedFallbackUnansweredStreak
        case chainedFallbackUnhelpfulReplyStreak
        case chainedFallbackAttemptCount
        case chainedFallbackAnswerCount
        case chainedFallbackRescueCount
        case dnsTierHealth
    }

    /// Creates a snapshot from explicit health timestamps, counters, and status fields.
    public init(
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        networkKind: TunnelNetworkKind = .unknown,
        lastResolverAddress: String? = nil,
        lastFailureReason: String? = nil,
        cacheHitCount: Int = 0,
        cacheMissCount: Int = 0,
        coalescedQueryCount: Int = 0,
        upstreamSuccessCount: Int = 0,
        upstreamFailureCount: Int = 0,
        consecutiveUpstreamFailureCount: Int = 0,
        lastResolverTransport: DNSResolverTransport = .plainDNS,
        dohHTTPFailureCount: Int = 0,
        lastDoHHTTPVersion: String? = nil,
        upstreamTimeoutCount: Int = 0,
        udpTruncatedResponseCount: Int = 0,
        tcpFallbackAttemptCount: Int = 0,
        tcpFallbackSuccessCount: Int = 0,
        deviceDNSFallbackAttemptCount: Int = 0,
        deviceDNSFallbackSuccessCount: Int = 0,
        deviceDNSUnavailableCount: Int = 0,
        networkPathIsSatisfied: Bool = true,
        lastDNSSmokeProbeAt: Date? = nil,
        lastDNSSmokeProbeSucceeded: Bool? = nil,
        dnsSmokeProbeSuccessCount: Int = 0,
        dnsSmokeProbeFailureCount: Int = 0,
        consecutiveDNSSmokeProbeFailureCount: Int = 0,
        consecutiveRejectedSmokeResponseCount: Int = 0,
        rejectedSmokeResponseResolverIdentity: String? = nil,
        rejectedSmokeResponseRescopeCount: Int = 0,
        deviceDNSFallbackModeActive: Bool = false,
        lastDeviceDNSFallbackActivatedAt: Date? = nil,
        deviceDNSFallbackActivationCount: Int = 0,
        resolverAttemptCounts: [String: Int] = [:],
        resolverSuccessCounts: [String: Int] = [:],
        resolverFailureCounts: [String: Int] = [:],
        lastNetworkChangeAt: Date? = nil,
        networkChangeCount: Int = 0,
        lastResolverRuntimeResetAt: Date? = nil,
        lastResolverRuntimeResetReason: String? = nil,
        lastResolverIdentityChangeAt: Date? = nil,
        resolverRuntimeResetCount: Int = 0,
        lastUpstreamSuccessAt: Date? = nil,
        lastPrimaryUpstreamSuccessAt: Date? = nil,
        lastEncryptedFallbackSuccessAt: Date? = nil,
        lastUpstreamFailureAt: Date? = nil,
        lastUpstreamDurationMilliseconds: Int? = nil,
        lastUpstreamSuccessDurationMilliseconds: Int? = nil,
        upstreamLatencyHistogram: DNSLatencyHistogram = DNSLatencyHistogram(),
        slowUpstreamResponseCount: Int = 0,
        consecutiveSlowUpstreamResponseCount: Int = 0,
        lastSlowUpstreamResponseAt: Date? = nil,
        lastNetworkSettingsReapplyFailureAt: Date? = nil,
        lastNetworkSettingsReapplyFailureReason: String? = nil,
        networkSettingsReapplyFailureCount: Int = 0,
        failClosedServedQueryCount: Int = 0,
        lastFailClosedAt: Date? = nil,
        lastFailClosedReason: String? = nil,
        lockedBootBlockedQueryCount: Int = 0,
        lockedBootAllowedQueryCount: Int = 0,
        lockedBootFailClosedQueryCount: Int = 0,
        lockedBootWindowEndedAt: Date? = nil,
        isChainedUpstreamActive: Bool = false,
        chainedTunnelDNSAnsweredCount: Int = 0,
        chainedTunnelDNSUnansweredCount: Int = 0,
        chainedTunnelDNSOutageCount: Int = 0,
        chainedLinkOutageCount: Int = 0,
        chainedUnansweredDestinationCount: Int = 0,
        chainedLongestUnansweredDestinationSeconds: Int = 0,
        chainedDataPathTransmitWindowBytes: UInt64 = 0,
        chainedDataPathReceiveWindowBytes: UInt64 = 0,
        chainedDataPathHasHandshake: Bool = false,
        chainedFallbackEvaluated: Bool = false,
        chainedFallbackLatchedAddresses: [String] = [],
        chainedFallbackLatchedIdentity: String = "",
        chainedFallbackAttemptKeys: [String] = [],
        chainedFallbackLatchedConfigurationFingerprint: String = "",
        runningChainedUpstreamGeneration: UInt64 = 0,
        chainedFallbackEffectiveAddresses: [String] = [],
        chainedFallbackRetiredAddresses: [String] = [],
        chainedFallbackOutcomes: [ChainedFallbackAddressOutcome] = [],
        chainedFallbackUnansweredStreak: Int = 0,
        chainedFallbackUnhelpfulReplyStreak: Int = 0,
        chainedFallbackAttemptCount: Int = 0,
        chainedFallbackAnswerCount: Int = 0,
        chainedFallbackRescueCount: Int = 0,
        dnsTierHealth: [DNSResolverTierHealthSnapshot] = []
    ) {
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.networkKind = networkKind
        self.lastResolverAddress = lastResolverAddress
        self.lastFailureReason = lastFailureReason
        self.cacheHitCount = cacheHitCount
        self.cacheMissCount = cacheMissCount
        self.coalescedQueryCount = coalescedQueryCount
        self.upstreamSuccessCount = upstreamSuccessCount
        self.upstreamFailureCount = upstreamFailureCount
        self.consecutiveUpstreamFailureCount = consecutiveUpstreamFailureCount
        self.lastResolverTransport = lastResolverTransport
        self.dohHTTPFailureCount = dohHTTPFailureCount
        self.lastDoHHTTPVersion = lastDoHHTTPVersion
        self.upstreamTimeoutCount = upstreamTimeoutCount
        self.udpTruncatedResponseCount = udpTruncatedResponseCount
        self.tcpFallbackAttemptCount = tcpFallbackAttemptCount
        self.tcpFallbackSuccessCount = tcpFallbackSuccessCount
        self.deviceDNSFallbackAttemptCount = deviceDNSFallbackAttemptCount
        self.deviceDNSFallbackSuccessCount = deviceDNSFallbackSuccessCount
        self.deviceDNSUnavailableCount = deviceDNSUnavailableCount
        self.networkPathIsSatisfied = networkPathIsSatisfied
        self.lastDNSSmokeProbeAt = lastDNSSmokeProbeAt
        self.lastDNSSmokeProbeSucceeded = lastDNSSmokeProbeSucceeded
        self.dnsSmokeProbeSuccessCount = dnsSmokeProbeSuccessCount
        self.dnsSmokeProbeFailureCount = dnsSmokeProbeFailureCount
        self.consecutiveDNSSmokeProbeFailureCount = consecutiveDNSSmokeProbeFailureCount
        self.consecutiveRejectedSmokeResponseCount = consecutiveRejectedSmokeResponseCount
        self.rejectedSmokeResponseResolverIdentity = rejectedSmokeResponseResolverIdentity
        self.rejectedSmokeResponseRescopeCount = rejectedSmokeResponseRescopeCount
        self.deviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        self.lastDeviceDNSFallbackActivatedAt = lastDeviceDNSFallbackActivatedAt
        self.deviceDNSFallbackActivationCount = deviceDNSFallbackActivationCount
        self.resolverAttemptCounts = resolverAttemptCounts
        self.resolverSuccessCounts = resolverSuccessCounts
        self.resolverFailureCounts = resolverFailureCounts
        self.lastNetworkChangeAt = lastNetworkChangeAt
        self.networkChangeCount = networkChangeCount
        self.lastResolverRuntimeResetAt = lastResolverRuntimeResetAt
        self.lastResolverRuntimeResetReason = lastResolverRuntimeResetReason
        self.lastResolverIdentityChangeAt = lastResolverIdentityChangeAt
        self.resolverRuntimeResetCount = resolverRuntimeResetCount
        self.lastUpstreamSuccessAt = lastUpstreamSuccessAt
        self.lastPrimaryUpstreamSuccessAt = lastPrimaryUpstreamSuccessAt
        self.lastEncryptedFallbackSuccessAt = lastEncryptedFallbackSuccessAt
        self.lastUpstreamFailureAt = lastUpstreamFailureAt
        self.lastUpstreamDurationMilliseconds = lastUpstreamDurationMilliseconds
        self.lastUpstreamSuccessDurationMilliseconds = lastUpstreamSuccessDurationMilliseconds
        self.upstreamLatencyHistogram = upstreamLatencyHistogram
        self.slowUpstreamResponseCount = slowUpstreamResponseCount
        self.consecutiveSlowUpstreamResponseCount = consecutiveSlowUpstreamResponseCount
        self.lastSlowUpstreamResponseAt = lastSlowUpstreamResponseAt
        self.lastNetworkSettingsReapplyFailureAt = lastNetworkSettingsReapplyFailureAt
        self.lastNetworkSettingsReapplyFailureReason = lastNetworkSettingsReapplyFailureReason
        self.networkSettingsReapplyFailureCount = networkSettingsReapplyFailureCount
        self.failClosedServedQueryCount = failClosedServedQueryCount
        self.lastFailClosedAt = lastFailClosedAt
        self.lastFailClosedReason = lastFailClosedReason
        self.lockedBootBlockedQueryCount = lockedBootBlockedQueryCount
        self.lockedBootAllowedQueryCount = lockedBootAllowedQueryCount
        self.lockedBootFailClosedQueryCount = lockedBootFailClosedQueryCount
        self.lockedBootWindowEndedAt = lockedBootWindowEndedAt
        self.isChainedUpstreamActive = isChainedUpstreamActive
        self.chainedTunnelDNSAnsweredCount = chainedTunnelDNSAnsweredCount
        self.chainedTunnelDNSUnansweredCount = chainedTunnelDNSUnansweredCount
        self.chainedTunnelDNSOutageCount = chainedTunnelDNSOutageCount
        self.chainedLinkOutageCount = chainedLinkOutageCount
        self.chainedUnansweredDestinationCount = chainedUnansweredDestinationCount
        self.chainedLongestUnansweredDestinationSeconds = chainedLongestUnansweredDestinationSeconds
        self.chainedDataPathTransmitWindowBytes = chainedDataPathTransmitWindowBytes
        self.chainedDataPathReceiveWindowBytes = chainedDataPathReceiveWindowBytes
        self.chainedDataPathHasHandshake = chainedDataPathHasHandshake
        self.chainedFallbackEvaluated = chainedFallbackEvaluated
        self.chainedFallbackLatchedAddresses = chainedFallbackLatchedAddresses
        self.chainedFallbackLatchedIdentity = chainedFallbackLatchedIdentity
        self.chainedFallbackAttemptKeys = chainedFallbackAttemptKeys
        self.chainedFallbackLatchedConfigurationFingerprint =
            chainedFallbackLatchedConfigurationFingerprint
        self.runningChainedUpstreamGeneration = runningChainedUpstreamGeneration
        self.chainedFallbackEffectiveAddresses = chainedFallbackEffectiveAddresses
        self.chainedFallbackRetiredAddresses = chainedFallbackRetiredAddresses
        self.chainedFallbackOutcomes = chainedFallbackOutcomes
        self.chainedFallbackUnansweredStreak = chainedFallbackUnansweredStreak
        self.chainedFallbackUnhelpfulReplyStreak = chainedFallbackUnhelpfulReplyStreak
        self.chainedFallbackAttemptCount = chainedFallbackAttemptCount
        self.chainedFallbackAnswerCount = chainedFallbackAnswerCount
        self.chainedFallbackRescueCount = chainedFallbackRescueCount
        self.dnsTierHealth = dnsTierHealth
    }

    /// Decodes a snapshot, defaulting health fields absent from older payloads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.networkKind = try container.decode(TunnelNetworkKind.self, forKey: .networkKind)
        self.lastResolverAddress = try container.decodeIfPresent(String.self, forKey: .lastResolverAddress)
        self.lastFailureReason = try container.decodeIfPresent(String.self, forKey: .lastFailureReason)
        self.cacheHitCount = try container.decodeIfPresent(Int.self, forKey: .cacheHitCount) ?? 0
        self.cacheMissCount = try container.decodeIfPresent(Int.self, forKey: .cacheMissCount) ?? 0
        self.coalescedQueryCount = try container.decodeIfPresent(Int.self, forKey: .coalescedQueryCount) ?? 0
        self.upstreamSuccessCount = try container.decodeIfPresent(Int.self, forKey: .upstreamSuccessCount) ?? 0
        self.upstreamFailureCount = try container.decodeIfPresent(Int.self, forKey: .upstreamFailureCount) ?? 0
        self.consecutiveUpstreamFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveUpstreamFailureCount
        ) ?? 0
        self.lastResolverTransport = try container.decodeIfPresent(
            DNSResolverTransport.self,
            forKey: .lastResolverTransport
        ) ?? .plainDNS
        self.dohHTTPFailureCount = try container.decodeIfPresent(Int.self, forKey: .dohHTTPFailureCount) ?? 0
        self.lastDoHHTTPVersion = try container.decodeIfPresent(String.self, forKey: .lastDoHHTTPVersion)
        self.upstreamTimeoutCount = try container.decodeIfPresent(Int.self, forKey: .upstreamTimeoutCount) ?? 0
        self.udpTruncatedResponseCount = try container.decodeIfPresent(Int.self, forKey: .udpTruncatedResponseCount) ?? 0
        self.tcpFallbackAttemptCount = try container.decodeIfPresent(Int.self, forKey: .tcpFallbackAttemptCount) ?? 0
        self.tcpFallbackSuccessCount = try container.decodeIfPresent(Int.self, forKey: .tcpFallbackSuccessCount) ?? 0
        self.deviceDNSFallbackAttemptCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSFallbackAttemptCount
        ) ?? 0
        self.deviceDNSFallbackSuccessCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSFallbackSuccessCount
        ) ?? 0
        self.deviceDNSUnavailableCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSUnavailableCount
        ) ?? 0
        self.networkPathIsSatisfied = try container.decodeIfPresent(
            Bool.self,
            forKey: .networkPathIsSatisfied
        ) ?? true
        self.lastDNSSmokeProbeAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastDNSSmokeProbeAt
        )
        self.lastDNSSmokeProbeSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .lastDNSSmokeProbeSucceeded
        )
        self.dnsSmokeProbeSuccessCount = try container.decodeIfPresent(
            Int.self,
            forKey: .dnsSmokeProbeSuccessCount
        ) ?? 0
        self.dnsSmokeProbeFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .dnsSmokeProbeFailureCount
        ) ?? 0
        self.consecutiveDNSSmokeProbeFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveDNSSmokeProbeFailureCount
        ) ?? 0
        self.consecutiveRejectedSmokeResponseCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveRejectedSmokeResponseCount
        ) ?? 0
        self.rejectedSmokeResponseResolverIdentity = try container.decodeIfPresent(
            String.self,
            forKey: .rejectedSmokeResponseResolverIdentity
        )
        self.rejectedSmokeResponseRescopeCount = try container.decodeIfPresent(
            Int.self,
            forKey: .rejectedSmokeResponseRescopeCount
        ) ?? 0
        self.deviceDNSFallbackModeActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .deviceDNSFallbackModeActive
        ) ?? false
        self.lastDeviceDNSFallbackActivatedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastDeviceDNSFallbackActivatedAt
        )
        self.deviceDNSFallbackActivationCount = try container.decodeIfPresent(
            Int.self,
            forKey: .deviceDNSFallbackActivationCount
        ) ?? 0
        self.resolverAttemptCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .resolverAttemptCounts
        ) ?? [:]
        self.resolverSuccessCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .resolverSuccessCounts
        ) ?? [:]
        self.resolverFailureCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .resolverFailureCounts
        ) ?? [:]
        self.lastNetworkChangeAt = try container.decodeIfPresent(Date.self, forKey: .lastNetworkChangeAt)
        self.networkChangeCount = try container.decodeIfPresent(Int.self, forKey: .networkChangeCount) ?? 0
        self.lastResolverRuntimeResetAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastResolverRuntimeResetAt
        )
        self.lastResolverRuntimeResetReason = try container.decodeIfPresent(
            String.self,
            forKey: .lastResolverRuntimeResetReason
        )
        self.lastResolverIdentityChangeAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastResolverIdentityChangeAt
        )
        self.resolverRuntimeResetCount = try container.decodeIfPresent(
            Int.self,
            forKey: .resolverRuntimeResetCount
        ) ?? 0
        self.lastUpstreamSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastUpstreamSuccessAt)
        self.lastPrimaryUpstreamSuccessAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastPrimaryUpstreamSuccessAt
        )
        self.lastEncryptedFallbackSuccessAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastEncryptedFallbackSuccessAt
        )
        self.lastUpstreamFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastUpstreamFailureAt)
        self.lastUpstreamDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .lastUpstreamDurationMilliseconds
        )
        self.lastUpstreamSuccessDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .lastUpstreamSuccessDurationMilliseconds
        )
        self.upstreamLatencyHistogram = try container.decodeIfPresent(
            DNSLatencyHistogram.self,
            forKey: .upstreamLatencyHistogram
        ) ?? DNSLatencyHistogram()
        self.slowUpstreamResponseCount = try container.decodeIfPresent(
            Int.self,
            forKey: .slowUpstreamResponseCount
        ) ?? 0
        self.consecutiveSlowUpstreamResponseCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveSlowUpstreamResponseCount
        ) ?? 0
        self.lastSlowUpstreamResponseAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastSlowUpstreamResponseAt
        )
        self.lastNetworkSettingsReapplyFailureAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastNetworkSettingsReapplyFailureAt
        )
        self.lastNetworkSettingsReapplyFailureReason = try container.decodeIfPresent(
            String.self,
            forKey: .lastNetworkSettingsReapplyFailureReason
        )
        self.networkSettingsReapplyFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .networkSettingsReapplyFailureCount
        ) ?? 0
        self.failClosedServedQueryCount = try container.decodeIfPresent(
            Int.self,
            forKey: .failClosedServedQueryCount
        ) ?? 0
        self.lastFailClosedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastFailClosedAt
        )
        self.lastFailClosedReason = try container.decodeIfPresent(
            String.self,
            forKey: .lastFailClosedReason
        )
        self.lockedBootBlockedQueryCount = try container.decodeIfPresent(
            Int.self,
            forKey: .lockedBootBlockedQueryCount
        ) ?? 0
        self.lockedBootAllowedQueryCount = try container.decodeIfPresent(
            Int.self,
            forKey: .lockedBootAllowedQueryCount
        ) ?? 0
        self.lockedBootFailClosedQueryCount = try container.decodeIfPresent(
            Int.self,
            forKey: .lockedBootFailClosedQueryCount
        ) ?? 0
        self.lockedBootWindowEndedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lockedBootWindowEndedAt
        )
        self.isChainedUpstreamActive =
            try container.decodeIfPresent(Bool.self, forKey: .isChainedUpstreamActive) ?? false
        self.chainedTunnelDNSAnsweredCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedTunnelDNSAnsweredCount) ?? 0
        self.chainedTunnelDNSUnansweredCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedTunnelDNSUnansweredCount) ?? 0
        self.chainedTunnelDNSOutageCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedTunnelDNSOutageCount) ?? 0
        self.chainedLinkOutageCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedLinkOutageCount) ?? 0
        self.chainedUnansweredDestinationCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedUnansweredDestinationCount) ?? 0
        self.chainedLongestUnansweredDestinationSeconds =
            try container.decodeIfPresent(
                Int.self, forKey: .chainedLongestUnansweredDestinationSeconds) ?? 0
        self.chainedDataPathTransmitWindowBytes =
            try container.decodeIfPresent(UInt64.self, forKey: .chainedDataPathTransmitWindowBytes) ?? 0
        self.chainedDataPathReceiveWindowBytes =
            try container.decodeIfPresent(UInt64.self, forKey: .chainedDataPathReceiveWindowBytes) ?? 0
        self.chainedDataPathHasHandshake =
            try container.decodeIfPresent(Bool.self, forKey: .chainedDataPathHasHandshake) ?? false
        // Absent from any snapshot written before the fallback status surface existed. The
        // defaults are the honest reading of that absence: nothing evaluated, nothing admitted,
        // nothing tried — which `ChainedFallbackStatus` reports as `.awaitingSession` rather
        // than inventing a verdict for a session that never recorded one.
        self.chainedFallbackEvaluated =
            try container.decodeIfPresent(Bool.self, forKey: .chainedFallbackEvaluated) ?? false
        self.chainedFallbackLatchedAddresses =
            try container.decodeIfPresent([String].self, forKey: .chainedFallbackLatchedAddresses) ?? []
        self.chainedFallbackLatchedIdentity =
            try container.decodeIfPresent(String.self, forKey: .chainedFallbackLatchedIdentity) ?? ""
        self.chainedFallbackAttemptKeys =
            try container.decodeIfPresent([String].self, forKey: .chainedFallbackAttemptKeys) ?? []
        self.chainedFallbackLatchedConfigurationFingerprint =
            try container.decodeIfPresent(
                String.self, forKey: .chainedFallbackLatchedConfigurationFingerprint) ?? ""
        self.runningChainedUpstreamGeneration =
            try container.decodeIfPresent(
                UInt64.self, forKey: .runningChainedUpstreamGeneration) ?? 0
        self.chainedFallbackEffectiveAddresses =
            try container.decodeIfPresent([String].self, forKey: .chainedFallbackEffectiveAddresses) ?? []
        self.chainedFallbackRetiredAddresses =
            try container.decodeIfPresent([String].self, forKey: .chainedFallbackRetiredAddresses) ?? []
        self.chainedFallbackOutcomes =
            try container.decodeIfPresent(
                [ChainedFallbackAddressOutcome].self, forKey: .chainedFallbackOutcomes) ?? []
        self.chainedFallbackAttemptCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedFallbackAttemptCount) ?? 0
        self.chainedFallbackUnansweredStreak =
            try container.decodeIfPresent(Int.self, forKey: .chainedFallbackUnansweredStreak) ?? 0
        self.chainedFallbackUnhelpfulReplyStreak =
            try container.decodeIfPresent(Int.self, forKey: .chainedFallbackUnhelpfulReplyStreak) ?? 0
        self.chainedFallbackAnswerCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedFallbackAnswerCount) ?? 0
        self.chainedFallbackRescueCount =
            try container.decodeIfPresent(Int.self, forKey: .chainedFallbackRescueCount) ?? 0
        self.dnsTierHealth =
            try container.decodeIfPresent([DNSResolverTierHealthSnapshot].self, forKey: .dnsTierHealth) ?? []
    }

    /// The combined cache hit and miss count.
    public var totalCacheLookups: Int {
        cacheHitCount + cacheMissCount
    }

    /// The fraction of cache lookups that hit, or zero when no lookups were recorded.
    public var cacheHitRate: Double {
        guard totalCacheLookups > 0 else {
            return 0
        }

        return Double(cacheHitCount) / Double(totalCacheLookups)
    }

    /// The fraction of TCP fallback attempts that succeeded, or zero with no attempts.
    public var tcpFallbackSuccessRate: Double {
        guard tcpFallbackAttemptCount > 0 else {
            return 0
        }

        return Double(tcpFallbackSuccessCount) / Double(tcpFallbackAttemptCount)
    }

    /// The fraction of Device DNS fallback attempts that succeeded, or zero with no attempts.
    public var deviceDNSFallbackSuccessRate: Double {
        guard deviceDNSFallbackAttemptCount > 0 else {
            return 0
        }

        return Double(deviceDNSFallbackSuccessCount) / Double(deviceDNSFallbackAttemptCount)
    }

    // MARK: - Locked-boot window evidence (INV-PERSIST-2 / QA release gate)

    /// Buckets one served query into the locked-boot evidence counters. The caller gates
    /// on its locked-boot store flag, so these only move inside the
    /// reboot-before-first-unlock window. Fail-closed serves
    /// (`reason == .protectionUnavailable`) bucket separately regardless of `action` —
    /// a fail-closed block is not a blocklist match (the #164 honesty rule the
    /// session-wide `failClosedServedQueryCount` follows) — so the blocked/allowed
    /// counts are real pipeline classifications only.
    public mutating func recordLockedBootServe(action: FilterAction, reason: FilterDecisionReason) {
        if reason == .protectionUnavailable {
            lockedBootFailClosedQueryCount += 1
        } else if action == .block {
            lockedBootBlockedQueryCount += 1
        } else {
            lockedBootAllowedQueryCount += 1
        }
    }

    /// Stamps the end of the locked-boot window exactly once — the first readable reload
    /// wins, and repeated readable reloads are no-ops. The caller passes its LAST
    /// observed-locked instant, not the reload's wall clock (see
    /// ``lockedBootWindowEndedAt`` for why the conservative boundary is load-bearing).
    /// The counters freeze by the caller no longer routing serves here once
    /// `lockedBootWindowCovers` stops admitting decisions.
    public mutating func markLockedBootWindowEnded(at date: Date) {
        guard lockedBootWindowEndedAt == nil else {
            return
        }
        lockedBootWindowEndedAt = date
    }

    /// Whether a decision made at `decisionTime` belongs to the locked-boot window,
    /// compared against the last instant the shared content was actually OBSERVED locked
    /// — the frozen window-end stamp once the window ended, or the caller's live
    /// observation while it is still open. Never a raw "flag is still set" fast path:
    /// the locked-boot store flag clears only at the throttled readable reload, so it
    /// stays set for up to one refresh interval of POST-unlock traffic, and admitting on
    /// the flag alone would count that traffic as boot evidence — a post-unlock blocked
    /// query falsely satisfying the QA gate (Codex review, #381). The caller handles the
    /// certainly-locked case (a fresh canary probe observing locked NOW) before calling
    /// this, so genuine pre-unlock traffic is admitted exactly; everything else is
    /// admitted only up to the conservative boundary, and a never-locked boot (both
    /// values nil) admits nothing.
    public func lockedBootWindowCovers(decisionAt decisionTime: Date, lastObservedLockedAt: Date?) -> Bool {
        guard let boundary = lockedBootWindowEndedAt ?? lastObservedLockedAt else {
            return false
        }
        return decisionTime <= boundary
    }

    /// This snapshot with the CHAINED FALLBACK addresses stripped, for a bug report.
    ///
    /// The chained fallback is the one place a user hand-enters an arbitrary IPv4 — the custom
    /// resolver field takes anything, and a QA user pointing it at their own `10.x` names their
    /// internal network. The panel may see those addresses (it is the user's own device showing
    /// the user their own setting); a report they send us may not. The contract is already
    /// written beside `chainedFallbackEvaluated` and these fields broke it three fields later
    /// (Codex, PR #575).
    ///
    /// The DISPOSITIONS survive, because they are the diagnostic — which gate refused which entry
    /// — and carry no network detail. So does
    /// ``chainedFallbackLatchedConfigurationFingerprint``, which is opaque by construction. What
    /// is dropped is only the addresses themselves.
    ///
    /// Covers the INDIRECT projections too. Resolver-health evidence keys `lastResolverAddress`
    /// and the `resolver*Counts` maps by the address that served or was tried, and a T1 rung
    /// lands in them like any other — so clearing only the fallback fields left the same private
    /// address reaching the report by a longer road (Codex, PR #575).
    ///
    /// An earlier version of this comment claimed those fields "carry the user's DNS resolver,
    /// which is normally a public preset". That is false in chained mode and false for exactly
    /// the case this type introduced, which is why the leak survived the first fix. The claim is
    /// corrected rather than deleted: it is the reason the second round was needed.
    ///
    /// 🔴 What this CANNOT cover, stated because the limit is structural rather than a choice:
    /// the configuration's own `DNS =` entries also land in those maps while chained, and a
    /// tailnet resolver names the user's network as surely as a hand-entered one. Redacting them
    /// would require matching against the conf's resolver list, and carrying that list in this
    /// snapshot is the very disclosure being prevented — `resolverSelectionFingerprint` exists so
    /// it never travels. So T0 addresses remain, and that is a real gap for a separate change
    /// with its own design, not something this helper can close.
    ///
    /// pinned: BugReportBundleTests.testTheReportCarriesNoChainedFallbackAddresses
    public func redactingChainedFallbackAddresses() -> TunnelHealthSnapshot {
        var copy = self
        // Built BEFORE the sets are cleared: they are the only thing that identifies a chosen
        // address elsewhere in the snapshot, AND the only thing that says what it became.
        let identity = redactedFallbackIdentities()

        copy.chainedFallbackLatchedAddresses = []
        // CLEARED, not folded. It is a single opaque-to-us string built from the preset ID, the
        // transport and every endpoint, and for a Custom entry those endpoints are the user's own
        // resolver — the same disclosure the address lists above are cleared for. Nothing in a
        // report keys off it, so there is no placeholder to keep.
        copy.chainedFallbackLatchedIdentity = ""
        // CLEARED like the addresses, and for the sharper reason: an encrypted attempt key is the
        // endpoint's full `cacheIdentifier`, so a Custom DoH entry puts the user's own URL — path
        // and query included — in this array.
        copy.chainedFallbackAttemptKeys = []
        copy.chainedFallbackEffectiveAddresses = []
        // CLEARED like the rest. Its whole job is to be READ by `redactedFallbackIdentities()`
        // above — which has already run, on the un-cleared copy — so that a resolver this session
        // retired still folds. Shipping the list itself would hand over the very addresses the
        // fold exists to hide.
        copy.chainedFallbackRetiredAddresses = []
        copy.chainedFallbackOutcomes = chainedFallbackOutcomes.map {
            ChainedFallbackAddressOutcome(address: "", disposition: $0.disposition)
        }
        guard !identity.isEmpty else { return copy }

        if let last = lastResolverAddress, let redacted = identity[last] {
            // A placeholder rather than nil. WHICH TIER served the last query is exactly what a
            // triager wants to know, and it survives without the address.
            copy.lastResolverAddress = redacted
        }
        copy.resolverAttemptCounts = Self.foldingKeys(resolverAttemptCounts, onto: identity)
        copy.resolverSuccessCounts = Self.foldingKeys(resolverSuccessCounts, onto: identity)
        copy.resolverFailureCounts = Self.foldingKeys(resolverFailureCounts, onto: identity)
        return copy
    }

    /// Stands in for a genuinely T1 address in a redacted report.
    public static let redactedFallbackAddress = "<alternative-dns>"
    /// Stands in for a chosen address the configuration's own `DNS =` ALREADY carries.
    ///
    /// Distinct from ``redactedFallbackAddress`` because the evidence keyed by it is ordinary
    /// T0 traffic. A deduped address is latched and carries an `.alreadyPrimary` outcome, but
    /// is deliberately absent from the effective set — folding it in with the T1 totals made
    /// the report say Alternative DNS had served queries it never handled, and with a mixed
    /// selection summed real T1 counts together with primary ones (Codex, PR #575). It is
    /// still redacted, because a user can hand-enter their own `DNS =` address here and it names
    /// their network either way.
    public static let redactedDeduplicatedPrimaryAddress = "<vpn-dns>"
    /// Stands in for a chosen address that was refused before it could be queried.
    ///
    /// It should never key any of these maps — a refused address is never in the resolver route,
    /// so nothing is ever attempted through it. It exists so the mapping is TOTAL: were such a
    /// key ever to appear, folding it into the T1 bucket would invent alternative-DNS traffic
    /// out of an address the tunnel declined to use.
    public static let redactedRefusedFallbackAddress = "<alternative-dns-refused>"

    /// Each chosen address mapped to the placeholder that tells the truth about it.
    ///
    /// The per-address outcomes are the authority here — that is the question the type answers —
    /// with any latched address lacking one defaulting to the T1 placeholder, which is the
    /// conservative direction for privacy.
    private func redactedFallbackIdentities() -> [String: String] {
        var identity: [String: String] = [:]
        // THE COUNTER KEYS FIRST, because they are what the maps below are actually keyed by and
        // they are the only entry for an encrypted selection: the latched list carries the host
        // (`cloudflare-dns.com`) while an attempt is recorded under `doh:https://…`, so seeding
        // from the latched list alone folded nothing and redacted nothing for a Custom DoH
        // endpoint (Codex P1, PR #591). Seeded with the T1 placeholder, which is the
        // conservative direction; the per-address outcomes below overwrite where they know better,
        // and for a plain selection they key identically so nothing changes there.
        for key in chainedFallbackAttemptKeys where !key.isEmpty {
            identity[key] = Self.redactedFallbackAddress
        }
        for address in chainedFallbackLatchedAddresses where !address.isEmpty {
            identity[address] = Self.redactedFallbackAddress
        }
        // THE RETIRED SET, which the three lists above no longer name. A device-DNS rung's
        // addresses are a live capture, so a roam republishes the new set over the old one while
        // the counter maps keep the old address as a key — see
        // ``chainedFallbackRetiredAddresses`` (Codex P1, PR #592). Seeded with the T1
        // placeholder and BEFORE the effective list below, so a re-seen address is overwritten by
        // its current, better-known disposition rather than the other way round.
        for address in chainedFallbackRetiredAddresses where !address.isEmpty {
            identity[address] = Self.redactedFallbackAddress
        }
        for address in chainedFallbackEffectiveAddresses where !address.isEmpty {
            identity[address] = Self.redactedFallbackAddress
        }
        for outcome in chainedFallbackOutcomes where !outcome.address.isEmpty {
            switch outcome.disposition {
            case .admitted:
                identity[outcome.address] = Self.redactedFallbackAddress
            case .alreadyPrimary:
                identity[outcome.address] = Self.redactedDeduplicatedPrimaryAddress
            // `unavailableInFullTunnel` joins the refused placeholder rather than getting its
            // own: this map exists to redact addresses and fold their counters, and an address
            // that was never attempted has no counters to keep apart from one that was refused.
            // The DISPOSITION itself is published unredacted alongside, so a report still says
            // which of the two happened (PR #590).
            case .unusable, .unusableIPv6, .notRoutedBySplitTunnel, .unavailableInFullTunnel:
                identity[outcome.address] = Self.redactedRefusedFallbackAddress
            }
        }
        return identity
    }

    /// Chosen addresses folded onto their placeholders, SUMMING rather than dropping.
    ///
    /// The totals are the diagnostic — this tier was tried this many times and served that many —
    /// and they say nothing about which address did it. Dropping the entries instead would make a
    /// working fallback and an untried one look identical in a report.
    private static func foldingKeys(
        _ counts: [String: Int], onto identity: [String: String]
    ) -> [String: Int] {
        guard counts.keys.contains(where: { identity[$0] != nil }) else { return counts }
        var folded: [String: Int] = [:]
        for (address, count) in counts {
            folded[identity[address] ?? address, default: 0] += count
        }
        return folded
    }
}
