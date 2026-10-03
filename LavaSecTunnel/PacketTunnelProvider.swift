@preconcurrency import ActivityKit
import Foundation
import Darwin
import os
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecChainedUpstream
import LavaSecDNS
import LavaSecFilterPipeline
import LavaSecKit

// MARK: - Completion & helper types

// A tier-scoped repair opportunity, fenced to the evidence and network that admitted it.
// The final teardown rechecks these tokens; a success or handoff queued first retires the grant.
struct DeviceDNSTierRecaptureGrant: Sendable {
    let evidence: ResolverTierEvidence
    let contextIdentity: String
    let runtimeGeneration: Int
    let observationSequence: UInt64
}


struct TunnelCompletion: @unchecked Sendable {
    let handler: () -> Void

    func complete() {
        handler()
    }
}

struct AppMessageCompletion: @unchecked Sendable {
    private let completionClaim = CompletionClaim()
    let handler: ((Data?) -> Void)?
    let latencySpan: LatencySpan?

    init(handler: ((Data?) -> Void)?, latencySpan: LatencySpan? = nil) {
        self.handler = handler
        self.latencySpan = latencySpan
    }

    func complete(_ response: Data?) {
        guard completionClaim.claim() else { return }
        latencySpan?.end(details: ["status": response == nil ? "nil-reply" : "reply"])
        handler?(response)
    }
}

struct ResolverQueuedWork: Sendable {
    let start: @Sendable (@escaping @Sendable () -> Void) -> Void
    let discard: @Sendable () -> Void
}

final class ResolverWorkCompletion: @unchecked Sendable {
    private let completionClaim = CompletionClaim()
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func complete() {
        guard completionClaim.claim() else { return }
        handler()
    }
}

final class ResolverSmokeProbeTimeout: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(handler: @escaping @Sendable () -> Void) {
        self.workItem = DispatchWorkItem(block: handler)
    }

    func schedule(on queue: DispatchQueue, timeoutSeconds: Int) {
        queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: workItem)
    }

    func cancel() {
        workItem.cancel()
    }
}

struct ResolverHealthEffectHooks {
    var beforeResolverRuntimeReset: (() -> Void)?
    var afterResolverRuntimeReset: (() -> Void)?
    var beforeProtectionNotification: (() -> Void)?
    var beforePendingResolverFailures: (([PendingDNSResponse], String, String) -> Void)?
}

/// T1 recovery credit follows the caller's evidence boundary (PR #639).
/// Forwarded lookups take credit only after `completeForward` accepts their runtime,
/// lifetime and owned waiters. Smoke probes have no waiting client and instead require
/// their originating runtime generation. No path may credit an answer before its gate.
/// pinned: ChainedDNSEvidenceCounterSourceTests.testTheForwardingCreditWaitsForTheDeliveryGate
enum TierOneRungCreditTiming: Sendable {
    case deferredToDelivery
    case noClient(admittedAtRuntimeGeneration: Int)
}

enum ResolverQueryPurpose: Sendable {
    case forwarding
    case smokeProbe

    var usesIsolatedEncryptedConnection: Bool {
        switch self {
        case .forwarding:
            return false
        case .smokeProbe:
            return true
        }
    }
}

let dnsStateQueueSpecificKey = DispatchSpecificKey<Bool>()

@_silgen_name("LavaSecCopySystemDNSServers")
func LavaSecCopySystemDNSServers(_ buffer: UnsafeMutablePointer<CChar>, _ bufferLength: Int32) -> Int32

struct ResolverAdjustedRuntimeSnapshot: FilterRuntimeSnapshot {
    let base: any FilterRuntimeSnapshot
    let resolver: DNSResolverPreset

    var blockRuleCount: Int {
        base.blockRuleCount
    }

    var allowRuleCount: Int {
        base.allowRuleCount
    }

    var guardrailRuleCount: Int {
        base.guardrailRuleCount
    }

    var effectiveAllowRuleCount: Int {
        base.effectiveAllowRuleCount
    }

    var allowedSuffixGuardrailCoverage: [String: GuardrailScopeCoverage] {
        base.allowedSuffixGuardrailCoverage
    }

    /// FORWARDED, like every other member. Swapping the resolver does not change what the wrapped
    /// snapshot decides, so wrapping a fail-closed resident still blocks every lookup — and a
    /// concrete-type test for `FailClosedRuntimeSnapshot` silently missed exactly that, leaving a
    /// recovery from a resolver-changed fail-closed window with no nudge (Codex review, PR #645).
    var blocksEveryLookup: Bool {
        base.blocksEveryLookup
    }

    func decision(for rawDomain: String) -> FilterDecision {
        base.decision(for: rawDomain)
    }

    func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        base.decision(forNormalizedDomain: normalizedDomain)
    }
}

// The block-all fail-closed snapshot (INV-DNS-1's terminal degradation step) is
// `LavaSecKit.FailClosedRuntimeSnapshot`: it lives in the package so its block-every-
// domain / `.protectionUnavailable` semantics are asserted by executable tests
// (FailClosedRuntimeSnapshotTests) instead of source pins on the provider. It
// keeps only the install-site wiring, which PacketTunnelDNSRuntimeSourceTests pins.

struct TunnelNetworkSettingsBundle {
    let settings: NEPacketTunnelNetworkSettings
    // The mode these settings were built for, carried so the log sites report what was
    // actually claimed rather than what the configuration currently says.
    let mode: TunnelDataPathMode
    let tunnelAddress: String
    let dnsServerAddress: String
    let routeDescription: String
    // Which clear-text DNS these routes let the tunnel see (`INV-DNS-7`). Carried beside the
    // route description for the same reason that string names both families: a field log has
    // to show the coverage the session actually got. Derived from the plan, never spelled
    // here — the capture set is the route set.
    let dnsCaptureScope: DNSCaptureScope
}

struct NetworkPathUpdate: Sendable {
    let kind: TunnelNetworkKind
    let isSatisfied: Bool
    let statusDescription: String
}

/// The lock-guarded user-manual-rule diagnostic state.
///
/// Holds the adopted normalized rule snapshot and the session's `(ruleKind, action)` dedup set in
/// one place so both are read and written under a single lock. `recordManualRuleDecisionIfNeeded`
/// runs OFF `dnsStateQueue` (the packet read loop and the wake-replay queue) while
/// `adoptAppConfiguration` publishes a new snapshot ON it; without the lock the strong-reference
/// store is an unsynchronized cross-thread access (a data race in Swift's model, not merely a
/// torn-value concern), and the count the cap reads could split from the set it tracks. Rebuilt
/// only at configuration adoption, so the paid-limit rule sets (up to 1000 blocked + 1000 allowed)
/// are normalized once per configuration, never once per query.
struct ManualRuleDiagnosticState: Sendable {
    /// The normalized manual rules adopted at the last `adoptAppConfiguration`.
    var snapshot: ManualDomainRuleSnapshot?
    /// The `"<ruleKind>:<action>"` pairs already logged this session (at most four).
    var loggedKeys: Set<String> = []
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    override init() {
        super.init()
        #if DEBUG || LAVA_QA_TOOLS
        // Distinguishes a provider instantiated by iOS from one that never receives startTunnel.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "provider-initialized", details: [
            "processID": String(ProcessInfo.processInfo.processIdentifier),
            "appBuild": (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "",
            "sourceRevision": (Bundle.main.object(forInfoDictionaryKey: "LavaSourceRevision") as? String) ?? "",
        ])
        #endif
    }

    // The tunnel's addressing is owned by `TunnelRoutePlan`. The DNS proxy's address is the
    // same in every data-path mode — chaining renumbers the INTERFACE (to the configured
    // `[Interface]` Address, C7) but never moves the proxy. This alias exists for the
    // non-settings readers below (the device-DNS self-listener guard); the network settings
    // themselves are built from the plan for the LATCHED mode, so the literals appear in
    // exactly one place.
    static let tunnelDNSServerAddress = TunnelRoutePlan.dnsServerAddress
    /// The in-tunnel resolver's IPv6 listener (F3c). Excluded from the device-DNS capture for
    /// the same reason as the IPv4 address: reading our own proxy back would make it look like
    /// a network resolver and mask the real ones.
    static let tunnelDNSServerIPv6Address = TunnelRoutePlan.chainedDNSServerIPv6Address
    static let deviceDNSCaptureBufferLength = 1024
    // Whether this build can actually drive a chained upstream. TRUE since the S8.8b flip
    // slice: the provider constructs the runtime per start (buildChainedRuntimeIfLatched),
    // readPackets branches whole batches to the driver, sleep/wake/path feed it, the
    // teardown funnel retires it, and the surrender path restarts into DNS-only behind a
    // persisted suppression. The flip shipped LAST, alone, after C1-C7 each held on main
    // with a coupling-removal test (the plan's S8 CONSTRAINTS and merge order). The latch
    // still consults this ahead of the device terms, and a session that cannot be BUILT is
    // still unclaimable — every construction failure downgrades the latch before settings
    // are built.
    //
    // What TRUE still does not claim: any physical-interface DNS while chained.
    // `.chainedMode` egress permits no physical-interface transport (the leak guard).
    // User and filter DNS are SERVED since the S6 wiring: `.plainDNS` is carried through
    // the session to the latched configuration's selected resolvers — the route consult
    // sits before the allowance, `resolveTunnelledPlainDNS` runs the carry over the
    // interface-pinned socket — while the encrypted presets and every fallback rung stay
    // refused, and a residual truncated answer fails CLOSED per INV-DNS-1 (resolved
    // decision 3). No real user can reach it (Phase 4 / C8); on-device QA sees a
    // servable chained mode whose DNS works or fails closed, never around the tunnel.
    // pinned: TunnelDataPathLatchSourceTests.testTheBuildFlagIsFlippedAndStillConsulted
    static let buildSupportsChainedDataPath = true
    /// Stable for one exact installed extension binary. Version/build/revision alone collide for
    /// local builds (`1.3.0|1|`), so the helper streams the executable into the identity. A
    /// separate per-lifecycle UUID fences delayed callbacks from a retired provider when a
    /// replacement runs this exact same binary. Nil fails chained startup closed.
    static let chainedBuildIdentity: String? = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let revision = info["LavaSourceRevision"] as? String ?? ""
        return ChainedInstalledBuildIdentity.make(
            version: version,
            build: build,
            revision: revision,
            executableURL: Bundle.main.executableURL)
    }()
    static let chainedLifecycleEvidenceQueue = DispatchQueue(
        label: "com.lavasec.tunnel.chained-lifecycle-evidence", qos: .utility)
    var snapshot: any FilterRuntimeSnapshot = FilterSnapshot(blockRules: DomainRuleSet())
    var protectionPolicySnapshot: any FilterRuntimeSnapshot = FilterSnapshot(blockRules: DomainRuleSet())
    // Identity of the rule artifact currently resident in `snapshot` (nil for
    // the empty bootstrap and fail-closed snapshots). Guarded by snapshotQueue.
    // A live reload reads this to skip decoding an on-disk artifact that would
    // reproduce the resident snapshot — avoiding the 2x-resident memory peak
    // that jetsams the extension on large multi-list snapshots.
    var residentSnapshotIdentity: PreparedFilterSnapshotIdentity?
    // True while the resident snapshot is a FailClosedRuntimeSnapshot installed because
    // NO usable snapshot could be loaded/compiled (over budget, or a build failure such
    // as a blocklist whose upstream rotated past the catalog's pinned hash) — as opposed
    // to a transient DNS wedge. A snapshot-unavailable fail-closed blocks all DNS, so the
    // smoke probe always fails; restarting the extension cannot rebuild a missing
    // snapshot, so self-reconnect must NOT escalate (it only flickers the VPN). Guarded by
    // `snapshotQueue` alongside `residentSnapshotIdentity`.
    var residentFailClosedDueToUnavailableSnapshot = false
    // First client impact in the current failed-recovery window; dnsStateQueue-confined.
    var filteringUnavailableNoticeStartedAt: Date?
    // The shared delivery state is owned by dnsStateQueue, including delayed callbacks.
    var protectionNotificationDelivery = ProtectionNotificationDeliveryState()
    // True when the resident identity-bearing snapshot was compiled from a config with
    // at least one enabled blocklist (a genuine FILTERING snapshot), false when it is the
    // permissive pass-through built for an empty config. `loadCompiledSnapshot` returns a
    // non-nil identity for BOTH (the empty config yields `(baseSnapshot, expectedIdentity)`),
    // so identity alone can't tell them apart. The keep-last-known-good path reads this to
    // refuse degrading to a pass-through resident when the new config wants filtering —
    // keeping the pass-through would silently fail OPEN. Guarded by `snapshotQueue`
    // alongside `residentSnapshotIdentity`; only meaningful while identity is non-nil
    // (fail-closed commits set identity nil and leave this at its default false).
    var residentSnapshotHasEnabledFilters = false
    let snapshotQueue = DispatchQueue(label: "com.lavasec.tunnel.snapshot", qos: .utility)
    let blockedTTL: UInt32 = 1
    let pausedWouldBlockForwardTTL: UInt32 = 1
    private static let maxConcurrentResolverQueries = 8
    static let resolverQueryLifetimeSeconds: TimeInterval = 12
    let resolverQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver", qos: .utility, attributes: .concurrent)
    let resolverSmokeProbeQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver.smoke-probe", qos: .utility)
    // Pending payloads and client waiters have independent count/byte ceilings. Expired
    // active I/O retains its slot until its callback retires the lease (INV-DNS-6).
    // pinned: PacketTunnelDNSRuntimeSourceTests.testForwardedLifetimeReachesAdmissionTransportsAndDelivery
    let resolverAdmissionQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver.admission", qos: .utility)
    let resolverConcurrencyAdmission = BoundedWorkAdmission<ResolverQueuedWork>(
        bound: PacketTunnelProvider.maxConcurrentResolverQueries
    )
    var resolverAdmissionExpiryTask: Task<Void, Never>?
    var resolverAdmissionExpiryDeadline: MonotonicDeadline?
    let protectionPauseStateQueue = DispatchQueue(label: "com.lavasec.tunnel.protection-pause-state", qos: .utility)
    // DispatchSerialQueue (not plain DispatchQueue) so dispatch-backed actors can adopt
    // it as their executor (INV-QUEUE-1 actors migration, slice 1) — every existing
    // async/sync/specific-key use is source-compatible (it IS-A DispatchQueue).
    let dnsStateQueue: DispatchSerialQueue = {
        let queue = DispatchSerialQueue(label: "com.lavasec.tunnel.dns-state", qos: .utility)
        queue.setSpecific(key: dnsStateQueueSpecificKey, value: true)
        return queue
    }()
    // INV-DNS-4 wiring: canonical resolver-health evidence and smoke-probe ownership live on
    // dnsStateQueue. Provider code projects the actor's bounded state into the persisted
    // health snapshot, then executes emitted IO effects synchronously in reducer order.
    // pinned: PacketTunnelDNSRuntimeSourceTests.testResolverHealthUsesOneCoordinatorChokepoint
    lazy var resolverHealthCoordinator = ResolverHealthCoordinator(
        queue: dnsStateQueue
    )
    static let udpDNSTimeoutSeconds = 1
    static let tcpDNSTimeoutSeconds = 2
    private static let dohTimeoutSeconds = 5
    private static let dotTimeoutSeconds = 5
    private static let doqTimeoutSeconds = 5
    // Routine smoke-probe timeout (health checks, startup): generous, since these
    // aren't latency-critical and a long timeout avoids false negatives.
    private static let resolverSmokeProbeTimeoutSeconds = 8
    // Recovery smoke-probe timeout (dns-recovery optimization A). The 1758 device
    // log showed the ~12s handoff blip was dominated by the 8s probe timeout
    // gating "am I back yet?" detection before self-reconnect fired (probe started
    // 07:55:27, failed 07:55:36, self-reconnect 07:55:38, recovered 07:55:39).
    // Sized to cover the first device/plain resolver's full failover (UDP 1s + TCP
    // 2s = 3s) PLUS a secondary resolver's UDP attempt (1s): a reachable secondary
    // answers via UDP in well under a second, so this no longer masks a working
    // secondary when the first address is blackholed (review note), while still
    // detecting an all-dead resolver set ~4s sooner than the routine 8s. Trade-off:
    // a slow-but-alive resolver on a high-latency network, or a secondary that
    // needs TCP, may cost one extra self-reconnect — bounded and self-healing (the
    // restart re-captures and the next query fails over).
    private static let resolverRecoveryProbeTimeoutSeconds = 4
    // Probe reasons that run while the user may be wedged, where fast detection
    // matters; everything else (periodic-health-check, startTunnel,
    // configuration-changed) keeps the routine timeout. The exhaustion
    // verification belongs here (UR-55, PR #342 review): after a REAL handoff it
    // is the first wire check that can classify the preserved Device-DNS primary
    // as dead, and the routine 8s would delay the fallback/wedge evidence the
    // exhaustion branch exists to apply promptly. On the stable-network side of
    // UR-55 the probe answers in milliseconds, so the short timeout costs nothing.
    private static let recoveryContextProbeReasons: Set<String> = [
        "network-settled",
        "resolver-wedge-recovery",
        "device-dns-fallback-recovery",
        "device-dns-exhaustion-verification"
    ]
    // The short four-second budget is for UDP-based recovery with no fallback. Encrypted
    // transports and primary-plus-fallback probes need the routine budget; cutting them short
    // could deactivate a working fallback before the probe's second leg finishes.
    static func smokeProbeTimeoutSeconds(
        reason: String,
        transport: DNSResolverTransport,
        canUseDeviceDNSFallback: Bool
    ) -> Int {
        let isFastPrimary = transport == .deviceDNS || transport == .plainDNS
        if recoveryContextProbeReasons.contains(reason), isFastPrimary, !canUseDeviceDNSFallback {
            return resolverRecoveryProbeTimeoutSeconds
        }
        return resolverSmokeProbeTimeoutSeconds
    }
    let resolverBackoffStateQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver-backoff", qos: .utility)
    // Recreated per lifecycle in `startPathMonitor` (hence `var`): a cancelled
    // NWPathMonitor delivers ZERO updates when restarted, so reusing one object
    // across a same-instance stop/start (manual toggle, or a
    // setTunnelNetworkSettings-error retry) would leave handleNetworkPathUpdate
    // permanently silent — no network-change reset, no settle probe, no
    // device-DNS recapture (field-confirmed 2026-06-22). A fresh monitor each
    // start guarantees the handler can fire again.
    // Patch discovery is lifecycle-scoped; endpoint membership and route reads are
    // dnsStateQueue-confined. No translated address is persisted across a restart.
    var dnsPatchDiscovery: DNSPatchRouteDiscovery?
    var dnsPatchObservedEndpoints: [String] = []
    var dnsPatchStartupInstallPolicy: DNSPatchStartupInstallPolicy?
    // Retained only after settings success while initial discovery is pending.
    var dnsPatchStartupInstallCompletion: (@Sendable (Error?) -> Void)?
    var dnsPatchContract: DNSPatchContract? {
        let values = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let id = values?[DNSPatchProviderCatalog.providerConfigurationKey] as? String ?? DNSPatchProviderCatalog.defaultID
        return try? DNSPatchProviderCatalog.contract(for: id)
    }
    var pathMonitor = Network.NWPathMonitor()
    static let resolverSmokeProbeInterval: TimeInterval = DeviceDNSFallbackPolicy.routineSmokeProbeInterval
    // How often the always-on tunnel checks for a Focus-committed config change (LAV-100 Phase 4 P4d). A
    // closed-app Focus switch is enforced within this window; short enough to feel prompt, long enough that
    // a cheap config-generation read per minute is negligible.
    static let focusConfigurationPollInterval: TimeInterval = 60
    // Fast recovery cadence for a same-network resolver wedge. Far shorter than
    // the 300s routine probe: when DNS is failed-closed, the user is offline now,
    // so re-probe (after clearing the backoff penalty box) until it recovers. One
    // re-probe per interval — not per query — so it never reintroduces the
    // dead-resolver hammering the backoff exists to prevent. The cadence escalates
    // from a tight first probe (LAV-92 "fast guide") and doubles up to the legacy
    // 30s ceiling, so a brief blip recovers in seconds while a sustained wedge
    // backs off to the gentle steady-state interval (== the old flat behaviour).
    let resolverWedgeRecoveryCadence = ResolverWedgeRecoveryCadence()
    // Zero-based count of consecutive re-probes in the current wedge episode; drives
    // the escalating cadence above and resets to 0 when the probe is cancelled
    // (recovery or lifecycle reset). dnsStateQueue-confined, like the work item.
    var resolverWedgeRecoveryAttempt = 0
    // Absolute fire deadline of the currently-armed probe (nil = none armed) and whether it was
    // armed on the gentle COVERED cadence. The scheduler preempts a pending probe when the cadence
    // MODE changed (covered<->uncovered — re-evaluate for online-vs-offline) OR a strictly-sooner
    // probe is now warranted within the same mode. dnsStateQueue-confined; armedCovered is only read
    // while armedDeadline != nil.
    var resolverWedgeRecoveryArmedDeadline: Date?
    var resolverWedgeRecoveryArmedCovered = false
    private let healthWriteInterval: TimeInterval = 30
    private let diagnosticsWriteInterval: TimeInterval = 30
    let configurationRefreshInterval: TimeInterval = 30
    let protectionPauseStateRefreshInterval: TimeInterval = 1
    // dnsStateQueue-confined, like the dictionaries they replaced.
    let dnsResponseCache = DNSResponseCache()
    let inFlightQueryCoalescer = InFlightDNSQueryCoalescer<PendingDNSResponse>()
    // Transient-bootstrap wait STATE machine extracted to TransientBootstrapDNSWait
    // (Phase E2). The INV-DNS-2 bounds (64-deep / 4 s) and the generation/expired-
    // generation transitions are executable there (TransientBootstrapDNSWaitTests);
    // the provider keeps the SERVFAIL writes, the replay through the filter, the
    // device-log events, and lifecycle-generation ownership (generations are passed
    // in per call, the machine never reads tunnel state). A dispatch-backed actor
    // on dnsStateQueue since actors slice 3 (INV-QUEUE-1) — confined call sites
    // reach it via synchronous assumeIsolated, with the one-shot timeout armed on
    // the same queue.
    lazy var transientBootstrapDNSWait = TransientBootstrapDNSWait<PendingDNSResponse>(
        queue: dnsStateQueue,
        scheduleAfter: { [dnsStateQueue] interval, body in
            let item = DispatchWorkItem(block: body)
            dnsStateQueue.asyncAfter(deadline: .now() + interval, execute: item)
            return item
        }
    )
    var resolverBackoffPolicy = ResolverBackoffPolicy()
    var health = TunnelHealthSnapshot()
    /// The prior chained data-path byte sample, differenced on the focus tick into the health
    /// snapshot's ~60 s transmit/receive window (Slice C). ONE sample, never a series
    /// (`INV-MEM-1`); nil in DNS-only mode and between sessions. dnsStateQueue-confined like `health`.
    var lastChainedDataPathStatsSample: ChainedRunnerStatistics?
    /// Per-session-generation latch for "this chained session has EVER handshaked", so the app can
    /// tell establishing (never → "Connecting…") from a session that handshaked and then expired
    /// (dead peer / keepalive-0 idle → a genuine "Down"). Advanced only via
    /// `currentChainedHandshakeState()`; reset when the driver's `sessionGeneration` changes or the
    /// chain goes away. dnsStateQueue-confined. (Kilo #556)
    var chainedHandshakeLatchGeneration: UInt64 = 0
    var chainedSessionEverHandshaked = false
    #if DEBUG || LAVA_QA_TOOLS
    /// QA leak-canary fire-once latch, keyed on the driver's `sessionGeneration` so the planted DNS
    /// canary fires exactly once per established chained session — the same generation-latch
    /// discipline as `chainedHandshakeLatchGeneration` above. dnsStateQueue-confined.
    var chainedLeakCanaryFiredForGeneration: UInt64 = 0
    /// The leak-canary nonce armed at THIS NE launch (snapshotted in `loadInitialSharedState`, before
    /// any handshake). The emitter fires only for the currently-armed nonce that equals this, so a
    /// nonce armed mid-session waits for a reconnect (a post-arm startTunnel) — matching the "fires at
    /// next connect" promise and keeping the canary from firing before the capture begins (Codex, PR
    /// #563). dnsStateQueue-confined. nil = nothing was armed at launch.
    var leakCanaryEligibleNonce: String?
    #endif
    var diagnostics = DiagnosticsStore()
    // SQLite depth store for Domain History (INV-MEM-1: O(1) appends instead of the JSON
    // store's O(rows) whole-blob rewrite, so it can hold the full 7-day window the 250-entry
    // `diagnostics.events` buffer cannot). The tunnel is the SOLE writer; the app opens it
    // read-only. Set once in `loadInitialSharedState` and thereafter appended on
    // `dnsStateQueue`; `DNSEventLog` is internally serial so the periodic prune can run off
    // that queue. Best-effort throughout — a log failure never affects filtering (INV-DNS-1).
    var dnsEventLog: DNSEventLog?
    var appConfiguration = AppConfiguration()
    var deviceDNSResolverAddresses: [String] = []
    // dnsStateQueue-confined (INV-QUEUE-1). Stamped by sleep(), consumed-and-cleared by the
    // next wake() to compute the suspension length for the brief-wake resolver-preserve
    // decision (DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake). nil when no
    // sleep was observed → wake takes the conservative full teardown.
    var resolverSleepBeganAt: Date?
    // dnsStateQueue-confined (INV-QUEUE-1). Last time ANY smoke probe actually hit the wire —
    // the anchor for the chronic-failure routine-probe backoff (UR-48 Phase 2a): the routine
    // tick keeps firing at the base cadence, but the wire query is skipped until the adaptive
    // interval has elapsed. Event-driven probes stamp too (their result is an equally fresh
    // sample), which only ever pushes the next routine probe out, never suppresses them.
    var lastWireSmokeProbeAt: Date?
    // dnsStateQueue-confined (INV-QUEUE-1). Episode-transition gate for the `device-dns-captured`
    // log line (UR-48 Phase 2a): the `count` and `reason` of the last line the gate allowed, plus
    // how many no-information repeats were suppressed since (reported on the next allowed line).
    // Tracking `reason` too keeps a masked→masked handoff under a new context loggable while still
    // collapsing same-reason repeats within one masked episode.
    var lastLoggedDeviceDNSCaptureCount: Int?
    var lastLoggedDeviceDNSCaptureReason: String?
    var suppressedDeviceDNSCaptureLogCount = 0
    // Bounds `dns-query-unanswered` so a sustained outage cannot evict the lifecycle, reset and
    // health lines that explain it from the bug report's 40-entry tail (Codex P2, PR #620). Its
    // own lock, unlike `suppressedDeviceDNSCaptureLogCount` above: the failure seams fire from
    // the read loop, `resolverQueue` and `dnsStateQueue`, so no single queue confines them.
    // 30 s matches the health-write debounce; the key vocabulary is a fixed reason x record
    // shape, never a domain, so the tracked set is bounded by construction.
    let unansweredDNSQuerySuppressor = RepeatedEventSuppressor(minimumInterval: 30)
    // Coalesce the per-query `dns-encrypted-fallback` debug marker. A wedged Device-DNS
    // primary routes EVERY organic query to the encrypted (Mullvad DoH) fallback, so a
    // per-query log floods the debug ring (~1.6k lines in a 6h flaky-network export,
    // evicting more useful events) for zero added signal. Log the first carried query of
    // an episode immediately, then throttle to one marker per interval carrying the count
    // since the last marker — that count preserves "how often the safety net saved a
    // wedge" without the spam. Reset on recovery so each new episode logs its first query.
    var encryptedFallbackCarriedSinceLastLog = 0
    var lastEncryptedFallbackLogAt: Date?
    let encryptedFallbackLogThrottleInterval: TimeInterval = 60
    var resolverSmokeProbeTimer: DispatchSourceTimer?
    // LAV-100 Phase 4 P4d: dedicated poll that adopts a Focus-committed filter switch made by the App
    // Intents extension while the app is closed. The extension can't push to the tunnel (sendProviderMessage
    // is app-only) and a tunnel-side Darwin observer was proven unreliable in the NE extension (0 callbacks /
    // 14 device probes — see PacketTunnelDNSRuntimeSourceTests), so the always-on tunnel POLLS the on-disk
    // configuration generation and reloads through the existing path when it advances. dnsStateQueue-confined.
    // Timer mechanism extracted to QueueConfinedRepeatingTimer (Phase E2); poll
    // POLICY (interval, tick, watermark rules) stays here with its pins.
    lazy var focusConfigurationPollTimer = QueueConfinedRepeatingTimer(queue: dnsStateQueue)
    var lastObservedConfigurationGeneration = 0
    var protectionPauseResumeTimer: DispatchSourceTimer?
    // INV-QUEUE-1: the coordinator owns only the reload generation and latest-owner in-flight marker on
    // dnsStateQueue. Provider adapters preserve dual-entry queue hops, while deferred completion remains
    // FIFO-after an adopted Focus watermark so a poll cannot restart a slow load before adoption is visible.
    lazy var snapshotReloadCoordinator = SnapshotReloadCoordinator(queue: dnsStateQueue)
    // INV-MEM-1: single-flights the in-extension snapshot compile so two overlapping reloads (a first-start
    // compile still running when a pull-to-refresh requests another) can never hold two ~32 MiB compile
    // peaks resident at once — ≈60 MiB in the 50 MB-limited NE process would jetsam the tunnel mid-serve.
    // The generation only fences the COMMIT; this gate serializes the peak itself. Wraps ONLY the compile
    // step in loadCompiledSnapshot (the cheap header reads stay concurrent), and the caller re-checks the
    // reload generation immediately before entering it so a superseded reload skips the compile entirely.
    let snapshotCompileGate = SnapshotCompileGate()
    var lastAppliedTemporaryProtectionPauseIsActive = false
    // dnsStateQueue-confined: marks the first DNS decision after tunnel start so
    // the "first DNS after start" latency target is measurable end to end.
    var hasRecordedFirstDNSDecision = false
    var firstDNSDecisionReferenceAt: Date?
    var tunnelStartLatencyOperationID: LatencyOperationID?
    var fallbackRecoverySmokeProbeWorkItem: DispatchWorkItem?
    // Pending same-network wedge-recovery re-probe (backoff reset + smoke probe),
    // scheduled while DNS is wedged and cancelled the moment it recovers.
    var resolverWedgeRecoveryWorkItem: DispatchWorkItem?
    // Pending bounded device-DNS capture retry (dns-recovery optimization C),
    // armed after a handoff/wake while the in-tunnel capture keeps coming back
    // empty (masked) and superseded on the next network change / wake / reset.
    // Cycle STATE machine extracted to DeviceDNSCaptureRetryCycle (Phase E2, after the
    // rc5 field log showed the wake-suppression cooldown being bypassed — see
    // DeviceDNSCaptureRetryCycleTests). The provider keeps the capture WORK. A
    // dispatch-backed actor on dnsStateQueue since actors slice 2 (INV-QUEUE-1) —
    // confined call sites reach it via synchronous assumeIsolated.
    lazy var deviceDNSCaptureRetryCycle = DeviceDNSCaptureRetryCycle(
        queue: dnsStateQueue,
        now: Date.init,
        scheduleAfter: { [dnsStateQueue] interval, body in
            let item = DispatchWorkItem(block: body)
            dnsStateQueue.asyncAfter(deadline: .now() + interval, execute: item)
            return item
        }
    )
    // Stamped when a full capture-retry cycle exhausts with the capture still masked, so
    // wake-triggered restarts of the cycle honour a cooldown on a chronically-masked
    // network (UR-48 follow-up log: median 5 s wake cadence restarted the 5x1 s cycle
    // continuously — ~1,500 masked reads over ~4.7 h with 108 exhaustions and zero
    // recoveries). Cleared on any non-wake schedule reason (a real network change) and
    // on the first non-empty capture. dnsStateQueue-confined.
    // (exhaustion stamp + suppression-log dedup now live in deviceDNSCaptureRetryCycle)
    var networkKind: TunnelNetworkKind = .unknown
    var lastConfigurationRefreshAt = Date.distantPast
    var lastProtectionPauseStateRefreshAt = Date.distantPast
    var cachedTemporaryProtectionPauseUntil: Date?
    var lastConfigurationModifiedAt: Date?
    var lastDiagnosticsControlModifiedAt: Date?
    // PST-1: the "already applied this clear request" markers are no longer in-memory
    // ivars (nil in every fresh process → the force-apply on every start re-wiped all
    // post-clear data). They now live durably on the diagnostics store itself
    // (`lastAppliedDomainHistoryClearAt` / `lastAppliedFilteringCountsClearAt`), written
    // in the same file the clear mutates.
    // Health and diagnostics share one debounced dirty-flush persistence machine
    // (extracted to LavaSecKit; replaces the two byte-for-byte-identical inline
    // copies that were the disk-churn class behind the 2026-06-14 heat regression).
    // Stateless scheduler → one instance serves both controllers; each owns its
    // own pending token. dnsStateQueue-confined, like the inline state it replaces.
    private lazy var persistenceFlushScheduler = DispatchSettleWorkScheduler(queue: dnsStateQueue)
    lazy var healthPersistence = DebouncedPersistenceController(
        writeInterval: healthWriteInterval,
        scheduler: persistenceFlushScheduler,
        write: { [weak self] _ in
            guard let self, let containerURL = LavaSecAppGroup.containerURL else {
                return false
            }
            // Deliberately NOT canary-gated (the #377 gate was removed with INV-PERSIST-2):
            // the health file is control-plane Class-None, so a pre-unlock write lands on a
            // WRITABLE file, and health is never reloaded from disk (resetHealth builds a
            // fresh snapshot each start) — there is no locked-file clobber class here. The
            // resident health is this session's real state; refusing it pre-unlock would
            // just delay the boot session's observability for nothing.
            let url = containerURL.appendingPathComponent(LavaSecAppGroup.tunnelHealthFilename)
            guard let data = try? JSONEncoder().encode(self.health) else {
                return false
            }
            // Control-plane options (INV-PERSIST-2): a Connect-On-Demand boot tunnel runs
            // and writes health BEFORE first unlock, where a Class-C write fails — and this
            // closure's `try?` + `return true` would clear the debounced dirty flag with
            // nothing persisted. Class-None keeps the boot tunnel's health writes landing.
            try? data.write(to: url, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
            return true
        }
    )
    lazy var diagnosticsPersistence = DebouncedPersistenceController(
        writeInterval: diagnosticsWriteInterval,
        scheduler: persistenceFlushScheduler,
        write: { [weak self] now in
            guard let self else {
                return false
            }
            // INV-PERSIST-1: a pre-unlock pass reads the locked diagnostics store as empty
            // and would atomically save that emptiness over the user's counts/history — and
            // this closure also drains the sqlite event log, which must equally wait for
            // first unlock. Returning false keeps the controller dirty; the same debounced
            // cadence retries post-unlock (Codex P2 round 5 on #377). The locked-boot gate
            // closes every post-unlock ordering race (Codex P1 rounds 6 + 7): a cadence
            // tick before the recovery reload, AND a stop-time forced flush after
            // endProtectionVPNSession dropped the pending-begin flag, both still see the
            // resident stores as locked-boot artifacts and refuse — the flag clears only
            // when loadDiagnosticsAndEventLogStores runs against readable content, in the
            // same dnsStateQueue turn as the reload it records. In a STOPPED lifecycle that
            // reload never comes, so the stop path abandons the refused retry instead of
            // letting it re-arm forever (see cleanUpTunnelRuntimeAfterStop).
            guard self.sharedProtectedContentIsReadable(),
                  !self.diagnosticsStoresReflectLockedBoot else {
                return false
            }
            self.diagnostics.resetForCurrentDayIfNeeded(now: now)
            // Prune the SQLite depth store below BOTH the 7-day fine-grained window AND the
            // app's "cleared at" floor, on the same debounced cadence the JSON store is
            // pruned/persisted. The floor makes a user's Clear Domain History / Clear All Logs
            // physically delete rows within one cadence (~30s) instead of leaving them
            // hidden-but-stored until they age out — the clear UI promises they leave the phone,
            // and the read path already hides them immediately via the same floor (PR #327
            // review). Cheap: the aging DELETE walks idx_event_action_ts per action (a bare
            // ts predicate full-scanned the whole table every pass — UR-53 follow-up,
            // 2026-07-12), mostly a no-op — the orphan sweep inside prune only runs on a pass
            // that actually deleted events (#339) — and off the DNS path.
            // Drain the event log's buffered best-effort appends, then prune — as ONE
            // primitive (`drainAndPruneDNSEventLog`): a buffered pre-clear event isn't a row
            // yet, so pruning before the drain leaves it to be re-inserted by a later flush
            // with its pre-clear timestamp; and draining without the coupled prune (or pruning
            // after a FAILED drain — a clear-contended commit retains its batch for retry) is
            // the same resurrection through a different door (P1s, lavasec-ios#54 promotion
            // review + PR #351 rounds 2/4).
            //
            // The result folds into this closure's return value: a pass whose prune was
            // skipped is INCOMPLETE even though the JSON diagnostics save below can still
            // succeed — returning `true` regardless would clear
            // DebouncedPersistenceController's dirty flag and cancel the guaranteed retry
            // (Codex catch, PR #351 round 3).
            // - pinned: PacketTunnelDNSRuntimeSourceTests.testDiagnosticsPersistenceFlushesBufferedDNSEventsBeforePruning
            let dnsEventLogPruneCompleted = self.drainAndPruneDNSEventLog(now: now, discardOnFailure: false)
            guard let diagnosticsURL = self.diagnosticsURL else {
                return false
            }
            // The JSON save's success folds into the return value alongside the prune result:
            // now that a false return is what arms the controller's self-scheduled retry, a
            // swallowed save failure would clear the dirty flag with the diagnostics
            // unpersisted and nothing re-trying (OCR P1, lavasec-ios#54 sync review — the
            // swallow itself predates #351, but the retry semantics made it load-bearing).
            let diagnosticsSaved = (try? DiagnosticsPersistence.save(self.diagnostics, to: diagnosticsURL)) != nil
            return dnsEventLogPruneCompleted && diagnosticsSaved
        }
    )
    let dohResolver = DoHTransport(timeoutSeconds: PacketTunnelProvider.dohTimeoutSeconds) { event, details in
        LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
    }
    let dotResolver = DoTTransport(timeoutSeconds: PacketTunnelProvider.dotTimeoutSeconds) { event, details in
        LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
    }
    let doqResolver = DoQTransport(timeoutSeconds: PacketTunnelProvider.doqTimeoutSeconds) { event, details in
        #if DEBUG || LAVA_QA_TOOLS
        if event == "dns-doq-connection-ready" {
            // NRG DoQ lever: count the fresh QUIC handshake + its duration atomically.
            //
            // NO LIFECYCLE VALIDATION HERE, and that is a property of the transport rather
            // than an omission. This closure is fixed at provider construction and a
            // handshake carries no session identity, so the seam PR #520 uses for the
            // chained-DNS evidence counters — validate the caller's generation + latch epoch
            // inside dnsStateQueue — has nothing to validate at this site. The guarantee is
            // bought upstream instead: `DoQTransport.cancel()` quiesces the transport at stop
            // and `resume()` re-arms it per lifecycle, so DoQ work started under a previous
            // session no longer reaches this line.
            //
            // With one residual, which the counter's reader should know about: a lane
            // cancellation that runs only AFTER the next `resume()` can still advance its
            // resolution's endpoint ladder into the new session, and the handshake that opens
            // there is counted here (Codex P1, PR #522 — see `DoQTransport.cancel`). Bounded
            // by how long a lane queue can lag a stop/start, and closed properly by
            // generation-tagged admission in its own slice.
            //
            // Scoping the WORK rather than the COUNT is the load-bearing choice: the
            // straggler's handshake was real radio energy in the next A/B battery cell, so a
            // counter taught to discard it would have disagreed with the battery it exists
            // to explain (see `DoQTransport.cancel`).
            // pinned: DoQTransportLifecycleTests.testACancelledTransportRefusesPooledWork
            EnergyCounters.shared.recordDoQHandshake(milliseconds: details["handshakeMs"].flatMap(Int.init))
            EnergySignpost.event("doq-handshake")       // NRG Phase 2: mark the handshake for Instruments
        }
        #endif
        #if !DEBUG
        // Drop the per-query DoQ "connection-ready" log OUTSIDE local DEBUG builds: in Release to
        // keep appendLine off the DNS success hot path, and in the LAVA_QA_TOOLS energy build so
        // the measured append rate + battery MATCH Release (the counter/signpost above already
        // captured the handshake). The rare connection-error events (the useful handoff signal)
        // still log; DoH/DoT pool connections, so their connection-ready stays on.
        if event == "dns-doq-connection-ready" { return }
        #endif
        LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
    }
    // One operation id groups all resolver-path latency spans (endpoint
    // attempts, device fallback, bootstrap) for a tunnel session. Only read
    // inside DEBUG/QA latency emission; harmless and unused in Release.
    let resolverLatencyOperationID = LatencyOperationID.make()
    // Memo of `DomainName.normalize` for resolver endpoint hostnames. normalize is pure and
    // deterministic (same input → same output), and the set of resolver hostnames is tiny and
    // stable for a resolver runtime. The memo is still runtime-scoped and capped so a future
    // dynamic caller cannot retain unbounded hostnames in a long-running extension process.
    // The bootstrap checks run first on EVERY DNS packet — including cache hits — and previously
    // re-normalized each candidate endpoint host per query (≈2–5 normalize calls/packet, each
    // doing IDNA/split/map allocations). This collapses the steady state to a dict lookup.
    // Thread-safe: read primarily from the serial packet callback queue, the lock is defensive
    // against any off-queue caller.
    static let endpointHostnameNormalizationCacheLimit = 32
    let endpointHostnameNormalizationCacheLock = NSLock()
    var endpointHostnameNormalizationCache: [String: String] = [:]
    var activeResolverRuntimeIdentifier: String?
    var resolverRuntimeGeneration = 0
    // INV-DNS-4: tier counters and repair evidence have their own context. A different tier's
    // successful rescue never clears this owner's failure; all state is dnsStateQueue-confined.
    var resolverTierObservedPathKind: TunnelNetworkKind?
    var resolverTierHealth = ResolverTierHealth()
    var resolverTierContextIdentity: String?
    var resolverTierSnapshotIdentity = UUID().uuidString
    var latestResolverTierEvidence: [DNSResolverTier: ResolverTierEvidence] = [:]
    var resolverTierRecoveryRetry: DispatchWorkItem?
    var resolverTierConfirmation: (id: UUID, tier: DNSResolverTier, sequence: UInt64)?
    // Send and observation ordering share this queue-owned clock. It deliberately survives
    // context resets; old callbacks cannot reuse a fresh incident's sequence (INV-DNS-4).
    var resolverTierObservationSequence: UInt64 = 0
    var lastResolverTierRecoveryLogSignature: String?
    // task #56: advances on a SATISFIED chained roam whose tunnelled carry survives (the one path
    // change that clears backoff WITHOUT bumping `resolverRuntimeGeneration`). The path monitor also
    // advances it at delivery before its deferred health update. Each tunnelled or plain/device
    // rung stamps this epoch — read live at THAT rung's send — onto its `ResolverAttempt.pathEpoch`;
    // `updateResolverBackoff` then records only the rungs whose epoch is still current. So a rung sent on
    // the degrading OLD link before the roam cannot re-stamp the backoff we just cleared (a stale-path
    // timeout is not evidence about the healthy new path), while a LATER rung of the same ladder sent on
    // the new path still backs off the resolver that timed out there (Codex, PR #565). Full resets need
    // no epoch bump: the generation gate already drops their stale completions before the backoff record.
    // dnsStateQueue-confined, like `resolverRuntimeGeneration`.
    var resolverBackoffPathEpoch = 0
    var tunnelLifecycleGeneration: UInt64 = 0
    // Synchronous admission gate for callbacks that can outlive stop-time source
    // cancellation. Generation guards reject lifecycle-bound callback work; this
    // bit additionally prevents any stale timer/work item from creating a new
    // smoke owner after invalidation and before final queue cleanup.
    var tunnelLifecycleIsActive = false
    var lastObservedPathKind: TunnelNetworkKind?
    var lastObservedPathIsSatisfied: Bool?
    // Freshest path-satisfied state the monitor has delivered, stamped SYNCHRONOUSLY
    // in the pathUpdateHandler — one dnsStateQueue hop earlier than
    // `health.networkPathIsSatisfied`, which handleNetworkPathUpdate applies via a
    // SECOND deferred hop. The self-reconnect teardown guard reads this so a path
    // update that has been delivered but whose deferred mutation hasn't landed yet
    // can't be missed (the cancel-into-dead-network race). Optimistic default (true)
    // matches "no adverse path info yet".
    var latestMonitoredPathIsSatisfied = true
    /// The live PRIMARY physical interface index, stamped synchronously in `pathUpdateHandler`
    /// from `path.availableInterfaces.first` (dnsStateQueue-confined, beside
    /// `latestMonitoredPathIsSatisfied`). F2's scoped physical binding: once the DNS capture
    /// floor claims a device resolver's route, a socket to it must egress on the interface the
    /// device actually routes over or it re-enters the tunnel and is refused. `nil` until the
    /// first path update and reset with the monitor restart, which the policy reads as "no safe
    /// physical pin" and answers `.systemChosen`.
    var latestPhysicalInterfaceIndex: UInt32?
    /// The tunnel-lifecycle generation that owns the one in-flight hands-free surrender-recovery
    /// task, or nil when none is running (dnsStateQueue-confined). A wedged `SecItem*` call never
    /// returns (`ChainedBoundedKeychainWork`'s premise), so without coalescing a flapping surrendered
    /// network would launch a new blocked global task on every satisfied transition, accumulating
    /// memory/thread pressure until the NE is jetsammed (`INV-MEM-1`, Codex, PR #569).
    ///
    /// Keyed on the OWNING generation, not a process-wide Bool: an `NEPacketTunnelProvider` instance
    /// can be stopped and REUSED for a new lifecycle, and a Bool wedged `true` by a hung Keychain op
    /// from the old lifecycle would block the new lifecycle's recovery forever — even though that
    /// stale task is generation-fenced and can no longer recover anyone. A new generation admits its
    /// own task (its generation differs from the stale marker); the stale task's clear is
    /// generation-matched so it cannot release the new task's slot (Codex, PR #569 round 13).
    /// Set to the owning generation before the task's Keychain work, cleared (if still ours) when it
    /// finishes.
    var chainedAutoRecoveryInFlightGeneration: UInt64?
    /// A superseded lifecycle's recovery cleared the store surrender but could not restart (its cancel
    /// fenced off to a newer generation); the newer lifecycle's SOLE initial complete-only read may
    /// have raced AHEAD of that clear write (the store is explicitly non-atomic — see
    /// `ChainedDeviceEligibilityStore.writePreservingSuppression`), leaving the new session latched
    /// DNS-only on a stationary network. This durable flag (dnsStateQueue-confined) hands the
    /// completion to the newer lifecycle: it is PUMPED when the in-flight recovery marker is next
    /// released, so the re-attempt reads the store strictly AFTER the racing read has finished.
    /// Event-driven on purpose — a fixed timer cannot bound the explicitly unbounded `SecItem*` read
    /// it must outlast (`ChainedBoundedKeychainWork`'s premise; Codex, PR #569 round 15).
    var chainedHandoffRecoveryPending = false
    #if DEBUG || LAVA_QA_TOOLS
    /// QA-only recovery-window instrumentation — the diagnostic for the post-network-change
    /// chained DNS gap ("TS IP connects instantly but sites don't load / feels patchy"). The
    /// `chained-session-liveness` line rides the 60 s focus tick, so a recovery falls entirely
    /// between two samples and its shape is invisible. This opens a bounded window on the two
    /// moments DNS is expected to be briefly down — chained cold-start and a meaningful network
    /// change — and samples the driver's liveness across it, stamping `elapsedMs` so the gap can
    /// be attributed (handshake wait vs interface-not-ready vs first-DNS lag).
    ///
    /// TWO resolution fixes over the first cut, both learned on device: (1) FINE cadence early
    /// (a coarse ~1.5 s tick could not tell a 200 ms recovery from a 1.4 s one — every roam read
    /// "~1500 ms" because that was the FIRST sample), and (2) keep sampling a few seconds PAST
    /// the first answer instead of closing on it, so a post-recovery timeout TAIL — the actual
    /// "patchy after it reconnects" shape — is visible as `dnsUnansΔ` climbing while `dnsAnsΔ`
    /// also climbs. dnsStateQueue-confined; self-terminating; never touches the DNS serving path.
    var chainedRecoveryWindowStartedAtMillis: Int?
    var chainedRecoveryWindowReason = ""
    var chainedRecoveryWindowBaselineAnswered = 0
    var chainedRecoveryWindowBaselineUnanswered = 0
    /// Elapsed ms at the FIRST tunnel-DNS answer past the baseline — the number the gap
    /// investigation actually wants. Nil until it lands.
    var chainedRecoveryFirstAnswerAtMillis: Int?
    /// Unanswered tunnel-DNS observations accumulated BEFORE that first answer, stamped with it.
    ///
    /// The validity qualifier for `firstAnswerMs`. Zero means nothing was asked and failed while
    /// the window ran, so the elapsed measures how long until traffic happened to arrive, not how
    /// long the tunnel took to recover. Nil until the first answer lands.
    var chainedRecoveryUnansweredBeforeFirstAnswer: Int?
    /// The unanswered delta as of the PREVIOUS sample — the only tally whose events are known to
    /// precede this one's.
    ///
    /// Counters carry totals, not order, so the current tick's delta cannot say whether a failure
    /// it counted happened before or after the answer counted alongside it. Both fit in one
    /// interval: the coarse cadence is 1500 ms and `udpDNSTimeoutSeconds` is 1 (Codex, PR #575).
    var chainedRecoveryUnansweredAtPreviousSample = 0
    /// Bumped on EVERY window (re)open so a pending fine/coarse tick from the PREVIOUS window
    /// is stale and no-ops instead of gating the new window's fine sample (Codex, PR #575): a
    /// second path change reopening a window mid-coarse-cadence must resume at 300 ms, or the
    /// old callback records its ≤1.5 s polling delay as the new window's `firstAnswerMs` — the
    /// very distortion the fine cadence removes.
    var chainedRecoveryWindowSerial: UInt64 = 0
    /// Fine cadence for the first few seconds (place a sub-second recovery), coarse after (the
    /// tail is a rate, not a millisecond edge). A ≤30 s hard cap bounds a peer that never
    /// returns; the window otherwise closes a fixed tail-window past the first answer.
    static let chainedRecoveryFineTickMillis = 300
    static let chainedRecoveryCoarseTickMillis = 1500
    static let chainedRecoveryFineUntilMillis = 3000
    static let chainedRecoveryTailMillis = 4000
    static let chainedRecoveryWindowCapMillis = 30_000
    #endif
    /// The lifecycle generation a surrender auto-recovery has already issued `cancelTunnelWithError`
    /// for (dnsStateQueue-confined; goes stale after a generation bump, no reset needed). The cancel
    /// is ASYNC to iOS, so the generation does NOT bump synchronously when we issue it — a SECOND
    /// recovery task that reaches the final fence for the SAME generation (a late fenced-off task
    /// that re-armed the handoff, or a same-generation re-admission after the coalescing marker freed
    /// but before this cancel lands) would otherwise issue a redundant second cancel for one
    /// lifecycle. Recording the cancelled generation makes the recovery cancel IDEMPOTENT per
    /// generation (adversarial panel, PR #569 round 17).
    var chainedRecoveryCancelIssuedGeneration: UInt64?
    // INV-QUEUE-1: logical boot recovery is lifecycle-owned; its physical Keychain slot
    // survives invalidation until the uncancellable read returns (INV-MEM-1).
    // pinned: ChainedBootRecoverySourceTests.testRecoveryReadsOffQueueAndRevalidatesUnderTheUserMutationFence
    var chainedBootRecoveryPolicy: ChainedBootRecoveryPolicy?
    var chainedBootRecoveryArmedGeneration: UInt64?
    var chainedBootRecoveryTimer: DispatchSourceTimer?
    var chainedBootRecoveryReadSlot = ChainedBootRecoveryReadSlot()
    var chainedBootRecoveryPathGate = ChainedBootRecoveryPathGate(generation: 0)
    var chainedBootRecoveryPathObservation: UInt64 = 0
    /// PROCESS-WIDE count of dispatched-but-not-yet-completed recovery global tasks, across ALL
    /// generations (dnsStateQueue-confined). The per-generation coalescing marker deliberately admits
    /// a NEW lifecycle's recovery even while an OLD generation's task is wedged in an unbounded
    /// `SecItem*` call (round 13 — so a reused instance can still recover). But that means lifecycle
    /// CHURN during a securityd wedge could dispatch one blocked global task per generation, each
    /// retaining `self` — an unbounded memory/thread accumulation until jetsam (`INV-MEM-1`). This
    /// count, bounded by `maxConcurrentChainedRecoveryTasks`, caps total in-flight physical work
    /// SEPARATELY from lifecycle ownership (Codex, PR #569 round 19).
    var chainedRecoveryInFlightTaskCount = 0
    /// The `INV-MEM-1` ceiling on concurrent recovery global tasks across all generations. Small so a
    /// securityd wedge + reconnect churn cannot pile up blocked `SecItem*` calls, yet > 1 so a new
    /// lifecycle can still admit its own recovery while one older task is wedged (round 13's premise).
    static let maxConcurrentChainedRecoveryTasks = 3
    /// A recovery refused because the process-wide ceiling was full retains its generation + mode here
    /// (dnsStateQueue-confined), so a slot drain RETRIES it for the current lifecycle on a stationary
    /// path — otherwise, when securityd recovers and the blocked tasks drain (usually declining, so
    /// they never set `chainedHandoffRecoveryPending`), the tunnel would stay surrendered until the
    /// next path callback despite capacity freeing (Codex, PR #569 round 20). Nil = nothing waiting.
    /// The mode is preserved so an initial-update refusal retries complete-only (never clears a
    /// genuine startup surrender), and a later satisfied-update refusal retries the full recovery.
    var chainedRecoveryCapacityWaitingGeneration: UInt64?
    var chainedRecoveryCapacityWaitingCompleteAbortedOnly = false
    /// When the last settings post happened, on the MONOTONIC clock — never the wall clock.
    ///
    /// `nil` until the first post, which reads as an infinite elapsed interval — the first post of
    /// a session is never throttled. A wall-clock `Date` here let a backward clock correction turn
    /// the interval negative, so the guard below failed and dropped every throttled post for the
    /// duration of the rollback (Codex review, PR #645). `DispatchTime` cannot run backwards.
    var lastNetworkSettingsReapplyUptime: DispatchTime?
    static let networkSettingsReapplyMinimumInterval: TimeInterval = 1
    /// Rule counts of the last adopted snapshot, for the loosening nudge below.
    /// dnsStateQueue-confined (`INV-QUEUE-1`): written and read only from the reload commit's
    /// queue block, alongside the other post-adoption state. `nil` until the first adoption of
    /// this session, which is never a loosening — see `FilterLooseningReapplyPolicy`.
    var lastAdoptedRuleCounts: FilterLooseningReapplyPolicy.RuleCounts?
    /// How many snapshots this provider instance has adopted THROUGH A COMMIT, for QA only.
    ///
    /// Open question this exists to answer (PR #645): whether to drop
    /// `FilterLooseningReapplyPolicy` and nudge on every adoption instead, which cannot miss any of
    /// the three documented blind spots but disturbs long-lived connections every time. That trade
    /// turns entirely on how often a real device adopts, and nothing measured it — neither existing
    /// event does. `ruleset-loosened-nudge` counts only the loosening subset, and
    /// `loadSnapshot-loaded` is emitted after `replaceSnapshot` returns WITHOUT testing
    /// `didCommitRealSnapshot`, so it also counts reloads the generation gate rejected.
    ///
    /// SCOPE, WHICH IS NARROWER THAN "EVERY RULESET THAT BECOMES RESIDENT" AND DELIBERATELY SO. A
    /// bootstrap install is not counted: `loadInitialSharedState` assigns the resident directly and
    /// seeds the baseline beside it, so the startup reload takes `residentSnapshotSatisfiesReload`'s
    /// no-op path and this recorder never runs (Codex review, PR #647). That is the right scope
    /// rather than a gap, because the population being measured is the one that would NUDGE:
    /// dropping the policy would post from this same recorder, which a bootstrap install does not
    /// reach either — and `startTunnel` posts settings itself at that moment, so a nudge there would
    /// be redundant. Counting bootstraps would overstate the cost of the alternative. The ongoing
    /// per-day rate is unaffected: every later switch, edit and catalog change commits through
    /// `replaceSnapshot` and is counted.
    ///
    /// dnsStateQueue-confined (`INV-QUEUE-1`), like the baseline above. Deliberately NOT reset
    /// beside `lastAdoptedRuleCounts` per session: the baseline must forget the previous session's
    /// ruleset to avoid comparing against it, whereas a rate is only meaningful ACROSS sessions —
    /// resetting it would restart the count on every same-instance restart and understate the rate.
    var adoptedSnapshotCount = 0
    // The user-manual-rule diagnostic's state — the adopted normalized rule snapshot and the
    // per-session `(ruleKind, action)` dedup set — behind ONE lock, so publication and reads are
    // synchronized rather than relying on a bare strong-reference assignment being atomic and
    // ordered. `recordManualRuleDecisionIfNeeded` reads it OFF `dnsStateQueue` (the packet read
    // loop's callback queue and the wake-replay queue) while `adoptAppConfiguration` publishes a
    // new snapshot ON it, and Swift does not guarantee a plain reference store is atomic across
    // threads: reading it lock-free was still a data race (Kilo round 3, PR #745). The lock's
    // critical sections are a pointer read, a count check and a tiny `Set` mutation, so the
    // per-query path still takes no `dnsStateQueue` hop (`INV-QUEUE-1`). Rebuilt only at adoption,
    // so the paid-limit rule sets (up to 1000 blocked + 1000 allowed) are normalized once per
    // configuration, never once per query.
    // pinned: ManualDomainRuleDiagnosticSourceTests.testTheManualRuleSnapshotIsPublishedUnderTheGuardedState
    let manualRuleDiagnosticState = OSAllocatedUnfairLock(initialState: ManualRuleDiagnosticState())
    // INV-CHAIN-1. The data path this session runs, decided ONCE per start by loadInitialSharedState —
    // which runs at startTunnel before any network settings are applied — and read by all
    // settings call sites through currentTunnelDataPathMode(). It is deliberately NOT
    // re-read from live configuration, because a running tunnel adopts AppConfiguration
    // changes without restarting: the 30 s serve-path refresh (configurationRefreshInterval),
    // the 60 s Focus poll (focusConfigurationPollInterval), the reload-configuration IPC
    // handler, and every snapshot-reload commit. reapplyTunnelNetworkSettings then rebuilds
    // settings on a network flap and on that same IPC path, so a live read would let a
    // mid-session config write — or merely walking between two Wi-Fi networks — change which
    // routes the tunnel claims, with no restart and nothing user-visible to explain it.
    // Chained mode transitions therefore go through a full restart, never a reload.
    //
    // loadInitialSharedState FULLY OWNS this pair, assigning both unconditionally on every
    // start. That matters for the startTunnel retry after a setTunnelNetworkSettings failure,
    // which re-enters start on the SAME provider instance and whose cleanup resets neither —
    // a prior lifecycle's latch must not survive into a new session.
    //
    // dnsStateQueue-confined (INV-QUEUE-1). The startup assignment precedes packet flow and
    // every later access goes through the dual-entry accessor.
    // pinned: TunnelDataPathLatchSourceTests.testTheModeIsLatchedInLoadInitialSharedState
    var latchedDataPathMode: TunnelDataPathMode = .dnsOnly
    /// The chained DNS fallback (T1) addresses LATCHED for this session, captured
    /// atomically with the chained latch in `installLatchedDataPathMode`. Empty when the
    /// fallback is off or the session is not chained.
    ///
    /// The configuration the T1 RUNG resolves against — the user's own resolver selection —
    /// latched with the mode, or `nil` when that selection cannot be a rung. Every transport the
    /// picker offers is eligible since PR #592, Device DNS included, so nil today means only
    /// "not chained, or not latched yet".
    ///
    /// THE ONLY T1 LATCH, and it used to be two. A `[String]` of plain-coerced addresses sat
    /// beside it, latched in the same write, and everything downstream — the admitted set, the
    /// panel's enumeration, the freshness comparison — was derived from that array rather than
    /// from this value. Two latched facts about one selection is two things that can disagree,
    /// and the coercion made them disagree by construction for any encrypted preset. This
    /// configuration carries the transport, the endpoints and the identity, so the derivations
    /// read one source (the plan's S4 obligation, "latch a transport-aware identity").
    ///
    /// LATCHED, NOT READ LIVE: the rung's resolver must not change under a session that is
    /// already running one, or the settings panel's counters describe a resolver the session
    /// stopped using (Codex PR #575 P1). The freshness comparison tells the user a restart is
    /// needed.
    ///
    /// A configuration snapshot rather than a plan, because a `DNSResolverRuntimePlan` also
    /// depends on the network kind, the device's resolvers and the health scheduler — all of
    /// which move DURING a session. The selection is what is fixed at latch; the plan is built
    /// per resolution from it (``currentTierOneFallbackPlan``). One `AppConfiguration` value type
    /// is a negligible resident cost against `INV-MEM-1`.
    var latchedChainedTierOneResolverConfiguration: AppConfiguration?
    /// Bumped on EVERY latch install, and only there — the latch's IDENTITY, distinct
    /// from `tunnelLifecycleGeneration` on purpose: the generation marks lifecycle
    /// boundaries (begin/invalidate) while the latch is written LATER in the prologue
    /// and can be rewritten within one generation (the construction downgrade), so
    /// "same generation" never proves "same latch". A tunnelled route seals this
    /// alongside the generation and every attempt validates both; a route derived
    /// under one latch can then never egress under another — the round-3 shape of the
    /// PR #518 race, where a stale resolution sealed a NEW generation over OLD chained
    /// addresses and a same-generation relatch to DNS-only made `.systemChosen`
    /// reachable for it. `dnsStateQueue`-confined with the latch it stamps.
    /// pinned: TunnelDataPathLatchSourceTests.testTheLatchHasExactlyOneWriterAndItBumpsTheEpoch
    var tunnelDataPathLatchEpoch: UInt64 = 0
    /// The rung LADDER POLICY the published fallback evidence was collected under.
    ///
    /// The published `chainedFallbackLatchedIdentity` names only the resolver the rung asks first,
    /// because that is what the panel's freshness check compares. The counters describe the whole
    /// LADDER, so they go stale for strictly more reasons: `fallbackToDeviceDNS`,
    /// `usesEncryptedDeviceDNSFallback` and the encrypted fallback preset all change whether a
    /// T1 attempt ends up answering, while leaving the resolver identity and the effective
    /// address set untouched. Scoped to the resolver alone, a policy relatch kept the old
    /// policy's attempts, rescues and streaks and the panel labelled the NEW policy working or
    /// broken on them (Codex P2, PR #599).
    ///
    /// Provider-local, not a snapshot field: it answers "was this evidence gathered under the
    /// ladder we are running now", which only this process can ask, and publishing it would put a
    /// second identity in bug reports that no reader can act on.
    var publishedFallbackEvidencePolicyIdentity: String = ""
    // Why `latchedDataPathMode` is not chained. Observability only for now: it is logged at
    // start so a device log explains a DNS-only session, and Phase 3 publishes it in health
    // state for the app-side reconcile.
    var latchedDataPathRefusal: TunnelDataPathLatch.Refusal?
    /// Whether the standing `.chainedSurrendered` refusal is one a network change can lift.
    ///
    /// `false` for every other refusal and for an unrecognised surrender reason, so the strict
    /// contract rule is the default and only a reason we have argued about relaxes it.
    /// pinned: ChainedSurrenderAutoRecoverySourceTests.testTheLatchRecoverabilityComesFromTheResolvedSnapshot
    var latchedSurrenderIsRecoverable = false
    /// Per-provider-lifecycle nonce stored beside the crash-loop marker. Nil for DNS-only and
    /// construction-downgraded latches. dnsStateQueue-confined with the data-path latch.
    var latchedChainedLifecycleEvidenceID: String?
    /// Revision of the cross-process terminal startup marker captured at this
    /// provider's start. Explicit Guard retries advance the shared revision so
    /// a retired provider cannot publish a late surrender into the new attempt.
    var chainedStartupFailureMarkerGeneration: UInt64 = 0
    /// The tunnel-lifecycle generation the current `latchedDataPathRefusal` was installed FOR
    /// (dnsStateQueue-confined, stamped by the sole latch writer). `tunnelLifecycleGeneration` bumps
    /// on invalidate (no active lifecycle) and at `startTunnel` BEFORE `loadInitialSharedState`
    /// installs this lifecycle's latch, and `latchedDataPathRefusal` carries the PREVIOUS lifecycle's
    /// value across that window — so a bare generation match is NOT proof the refusal belongs to a
    /// ready lifecycle. A consumer that could act on the refusal (the handoff pump's restart) must
    /// require `latchedDataPathRefusalGeneration == tunnelLifecycleGeneration` (Codex, PR #569 round 16).
    var latchedDataPathRefusalGeneration: UInt64?
    // Whether THIS session's startup actually completed — set in the post-settings success
    // path, reset with the rest of the per-session state in `resetHealth`. dnsStateQueue-
    // confined. Gates the teardown funnel's streak reset and boot recovery admission. A stopTunnel
    // arriving while setTunnelNetworkSettings is still pending enters the funnel as a clean
    // stop, but the session never ran, and resetting the jetsam streak on it would erase the
    // evidence of a repeatedly crashing device — a cancelled start is not proof the device
    // coped, any more than a failed one is (Codex, PR #499).
    // pinned: TunnelDataPathLatchSourceTests.testTheTeardownFunnelSettlesChainedTerminationEvidence
    var tunnelStartupDidComplete = false
    // Last-resort recovery: when DNS stays wedged after a handoff (device-DNS
    // resolvers can't be re-captured while the tunnel is active), restart the
    // tunnel so startup re-captures them. Latched so we issue the cancel once, and
    // the attempt history is persisted (the cancel kills this process) for the
    // cross-restart backoff in TunnelSelfReconnectPolicy.
    var hasRequestedSelfReconnect = false
    // Dedup state for the self-reconnect-suppressed device-log line. A persistent
    // wedge re-evaluates the policy on every failed query/tick, which previously
    // logged a suppressed line each time (hundreds per wedge), churning the size-
    // capped debug log and evicting useful diagnostics. We log only when the
    // suppression signature changes or after a cooldown, so the reason is still
    // captured without the storm.
    var lastSelfReconnectSuppressionSignature: String?
    var lastSelfReconnectSuppressionLogAt: Date?
    // Dedup state for the self-reconnect-skipped-path-unsatisfied line. While the
    // network path is unsatisfied the tunnel keeps receiving (failing) queries, so
    // the policy can re-decide .reconnect and re-skip on every one; share the same
    // cooldown the suppression line uses so a flapping handoff can't storm the log.
    var lastSelfReconnectPathSkipLogAt: Date?
    static let selfReconnectSuppressionLogInterval: TimeInterval = 60
    static let selfReconnectAttemptsDefaultsKeyName = "tunnel.selfReconnectAttemptTimes"
    // Restart-survivable marker for the productive-recovery credit (Track 4): the wall
    // time of the last committed self-reconnect, persisted just before the cancel kills
    // the process and read on the next launch. If the relaunched tunnel reaches a
    // confirmed primary recovery within `selfReconnectCreditWindow`, the attempt that led
    // to this launch is credited back (pruned from the shared attempt store) so a genuine
    // network switch nets ~0 against the cap; a restart that never recovers keeps its
    // attempt and accrues toward the cap (a true loop is bounded, a productive one isn't).
    static let lastSelfReconnectAtDefaultsKeyName = "tunnel.lastSelfReconnectAt"
    static let selfReconnectCreditWindow: TimeInterval = 120
    // Nudges the foreground app to pull fresh health (over the provider-message
    // channel) when the connectivity-relevant state changes, so the Dynamic
    // Island reflects reconnect/network-lost states without waiting for the next
    // app-side status poll (UR-6). Darwin works app-side because the app's run
    // loop is live; the tunnel only ever POSTS — it must not re-add the dormant,
    // unreliable extension-side observer that was deliberately removed.
    let connectivitySignalNotifier: any ProtectionSignalNotifier = DarwinProtectionSignalNotifier()
    var lastSignaledConnectivityKey: String?
    #if LAVA_QA_TOOLS
    var lastQAConnectivitySeverity: ProtectionConnectivitySeverity = .healthy
    var lastQAConnectivityLogAt = Date.distantPast
    #endif

    // MARK: - Stored state declared beside its concern before the file split
    //
    // Swift extensions cannot hold stored properties, so these moved here from the
    // Provider/ file named in each group; their doc comments travelled with them.

    // From Provider/PacketTunnelProvider+Lifecycle.swift:
    #if DEBUG || LAVA_QA_TOOLS
    let chainedAAAANoDataLock = NSLock()
    var chainedAAAANoDataCount: UInt64 = 0
    var lastChainedAAAANoDataLogAt: Date?
    let chainedIPv6HintStripLock = NSLock()
    var chainedIPv6HintStripCount: UInt64 = 0
    var lastChainedIPv6HintStripLogAt: Date?
    #endif

    /// The local source ports this process holds for its own tunnel-pinned resolver queries.
    ///
    /// PROCESS-LIFETIME, and that is the reason it lives here rather than on the runner or the
    /// factory: `ChainedOutageDriver` rebuilds the runner per attempt, so a runner-held registry
    /// would forget an in-flight retry's port at exactly the moment a reconnect happens — and a
    /// reconnect is when a retry is most likely to be outstanding. The forgotten retry would then
    /// be dropped as unfilterable DNS by the carve-out built to carry it.
    let ownResolverPorts = ChainedResolverPortRegistry(
        uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })

    // From Provider/PacketTunnelProvider+PacketLoop.swift:
    let dnsQueryDispatcher = DNSQueryDispatcher()

    // From Provider/PacketTunnelProvider+UpstreamForwarding.swift:

    // The egress decision is required at construction, so this cannot be built without
    // answering it — and it is answered from the LATCHED mode, per resolution.
    //
    // Three shapes were wrong before this one, each for a different reason:
    //
    // Deriving it from `buildSupportsChainedDataPath` used a process-wide fact for a
    // per-session question, so once that flag flips every DNS-only session would have had
    // device DNS and the encrypted fallback refused — SERVFAIL where they resolve today.
    //
    // Caching the latched value in a `lazy` property made it per-PROVIDER, and
    // NetworkExtension reuses providers across `startTunnel` while the latch re-resolves on
    // every start: a DNS-only → chained restart kept the permissive orchestrator, and the
    // reverse refused everything.
    //
    // Rebuilding the orchestrator per start fixed that and introduced a data race. Per-query
    // work reads this from the CONCURRENT `resolverQueue`; a write on every start races any
    // resolution still in flight from the previous session; active I/O can finish after stop.
    // The original design had exactly one initialisation and no writes, which is why its
    // comment says the lazy seams are forced single-threaded — that property was load-bearing
    // and I removed it.
    //
    // A CLOSURE keeps all three properties at once: built once, never written, and always
    // reading the mode this session actually latched.
    // pinned: TunnelDataPathLatchSourceTests.testTheOrchestratorCannotBeBuiltWithoutAnEgressDecision
    lazy var resolverOrchestrator = ResolverOrchestrator(
        executors: makeResolverExecutors(),
        egressAllowance: { [weak self] in
            // Absent provider means the tunnel is gone; refuse rather than permit. A resolution
            // outliving its provider must not be the one path that egresses freely.
            guard let self else { return .chainedMode }
            // THE SPLIT/FULL FAN-OUT, from the LATCHED configuration and nothing else. A split
            // tunnel sends general traffic direct on the physical interface, so the local
            // observer already holds the destination and the TLS SNI for every site — and the
            // T1 rung may take the path that traffic is already taking. Full tunnel keeps
            // the suspension whole, because there the tunnel really is hiding the destination
            // and DNS would be the only observable. `ChainedResolverEgressPolicy` owns the
            // decision; this reads the latch and asks it (plan
            // `2026-08-26-unified-resolver-picker-and-split-tunnel-tier-two-egress`).
            //
            // Derived per resolution from the latch, never from a stored preference, so a
            // profile that changes routing shape cannot inherit a permission granted to the
            // shape before it.
            // pinned: TunnelDataPathLatchSourceTests.testTheOrchestratorCannotBeBuiltWithoutAnEgressDecision
            switch self.currentTunnelDataPathMode() {
            case .chainedUpstream(let upstream):
                return ChainedResolverEgressPolicy.permitsTierOneFallbackOnPhysicalInterface(
                    chainedIsLatched: true, routingPolicy: upstream.containsFullTunnel ? .fullTunnel : upstream.routingPolicy)
                    ? .chainedSplitTunnelMode : .chainedMode
            case .dnsOnly:
                return .dnsOnlyMode
            }
        },
        // The S6 carry's route, derived per resolution from the LATCHED configuration —
        // the same closure shape, for the same three reasons, as `egressAllowance` above.
        // Delegates to `currentTunnelledPlainDNSRoute()`, which derives the addresses
        // AND the originating-lifecycle token in one critical section; see its doc.
        // pinned: TunnelDataPathLatchSourceTests.testTheTunnelledRouteIsTheLatchedConfigurationsSelectedResolvers
        tunnelledPlainDNSRoute: { [weak self] in
            self?.currentTunnelledPlainDNSRoute()
        },
        // Names the session a resolution is allowed to run under. Zero means "no session",
        // and both cases that produce it are refusals by construction: an absent provider,
        // and a lifecycle that has been invalidated but whose generation counter still holds
        // the number it ended on. Returning the raw counter in that second case would let a
        // resolution admitted in the dying session keep matching after the stop — the
        // activity bit is what distinguishes "between stop and cleanup" from "running", the
        // same distinction `currentTunnelledPlainDNSRoute` draws.
        // pinned: TunnelDataPathLatchSourceTests.testTheOrchestratorAdmitsWorkOnlyForTheLiveLifecycle
        admissionEpoch: { [weak self] in
            guard let self else { return 0 }
            return self.currentResolverAdmissionEpoch()
        },
        currentPathEpoch: { [weak self] in
            self?.currentResolverTierPathEpoch()
        },
        // T1 is the user's selected resolver, captured in the session latch. Without an
        // opted-in selection there is no physical rung and T0's response remains authoritative.
        // pinned: TunnelDataPathLatchSourceTests.testTheOrchestratorTakesTheTierOnePlanFromTheLatch
        tierOneFallbackPlan: { [weak self] in
            self?.currentTierOneFallbackPlan()
        })

    // From Provider/PacketTunnelProvider+ResolverTransports.swift:

    lazy var resolverBootstrapService = ResolverBootstrapService(
        resolveAddresses: { [weak self] hostname, admittedAtEpoch in
            guard let self else {
                return ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
            }

            let resolverAddresses = self.orderedResolverAddressesForCurrentNetwork(self.currentDeviceDNSResolverAddresses())
            guard !resolverAddresses.isEmpty else {
                return ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
            }

            #if DEBUG || LAVA_QA_TOOLS
            // Async pre-warm (off the packet path) but timed: a slow bootstrap
            // is what the synchronous-bootstrap extraction removed from the
            // hot path, so it stays worth ranking.
            let bootstrapSpan = Self.makeLatencyTrace(
                operationID: self.resolverLatencyOperationID,
                operationKind: "resolver"
            ).beginSpan("resolver.bootstrap")
            #endif
            let bootstrap = self.resolveDoQBootstrapAddresses(
                for: hostname, resolverAddresses: resolverAddresses, admittedAtEpoch: admittedAtEpoch)
            #if DEBUG || LAVA_QA_TOOLS
            bootstrapSpan.end(details: [
                "ipv4Count": "\(bootstrap.ipv4.count)",
                "ipv6Count": "\(bootstrap.ipv6.count)",
                "succeeded": "\(!bootstrap.ipv4.isEmpty || !bootstrap.ipv6.isEmpty)"
            ])
            #endif

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-bootstrap-resolved", details: [
                "hostname": hostname,
                "ipv4Count": "\(bootstrap.ipv4.count)",
                "ipv6Count": "\(bootstrap.ipv6.count)"
            ])

            return ResolverBootstrapService.ResolvedAddresses(ipv4: bootstrap.ipv4, ipv6: bootstrap.ipv6)
        }
    )

    /// Settle window for coalescing the proactive resolver rebuild across a burst
    /// of network-path flaps (plan item 430). Long enough to swallow a flapping
    /// cellular/Wi-Fi handoff, short enough that a genuine single change re-probes
    /// promptly. Confined to `dnsStateQueue`.
    private let resolverProbeSettleInterval: TimeInterval = 1.5

    lazy var resolverProbeCoalescer = NetworkSettleCoalescer(
        settleInterval: resolverProbeSettleInterval,
        scheduler: DispatchSettleWorkScheduler(queue: dnsStateQueue),
        work: { [weak self] in
            self?.performCoalescedNetworkSettleProbe()
        }
    )

    // From Provider/PacketTunnelProvider+BootstrapBroker.swift:

    /// Hostnames brokered during the CURRENT fail-closed window. Cleared when the tunnel
    /// leaves fail-closed, which is the event this broker exists to bring about.
    /// dnsStateQueue-confined, like the rest of the DNS state (INV-QUEUE-1).
    var brokeredBootstrapHostnames: Set<String> = []

    // From Provider/PacketTunnelProvider+ProtectionPause.swift:

    // Boot-deferred session begin (INV-PERSIST-1). Written OFF-queue by startTunnel's
    // deferral and consumed ON dnsStateQueue by the config-refresh flush, so access runs
    // through the specific-key accessors in Provider/PacketTunnelProvider+ProtectionPause.swift
    // (INV-QUEUE-1, same pattern as currentAppConfiguration/setAppConfiguration).
    var pendingFreshProtectionVPNSessionReason: String?

    // One-shot handoff from the deferred-begin flush to clearSnapshotReloadInFlight: the
    // recovery force yields to an in-flight reload (round 3) but must still fire if that
    // reload turns out to be the pre-unlock abort (round 8). Disarmed by reload
    // invalidation at stop so the superseded reload's late clear cannot fire it into a
    // stopped lifecycle (round 9), and by a successful adoption so the fire never resets
    // the DNS runtime behind a completed recovery (round 13). dnsStateQueue-confined —
    // the flush, the clear, the adoption disarm, and the invalidate all run on that queue.
    var deferredRecoveryReloadPending = false

    // Whether the RESIDENT diagnostics/depth stores were loaded from a locked
    // (pre-first-unlock) container and are therefore boot-empty placeholders that must
    // never persist (INV-PERSIST-1). Deliberately independent of the session-begin
    // lifecycle — a stop legitimately drops the pending begin, but that must not unblock
    // persisting the placeholder (Codex P1 round 7 on #377). Set/cleared only by
    // loadDiagnosticsAndEventLogStores from the canary at load time; boot assignment
    // precedes packet flow and every later access runs on dnsStateQueue (same confinement
    // story as `diagnostics` itself).
    var diagnosticsStoresReflectLockedBoot = false

    // The last instant a probe actually OBSERVED the shared protected content locked —
    // stamped at the begin's re-defer (every pre-unlock flush tick, post-INV-PERSIST-2
    // boots), the still-unreadable config classification (pre-migration boots), and the
    // locked-boot store load (boot). The locked-boot evidence window's END is stamped
    // with THIS, never the readable reload's own wall clock: the reload runs one flush
    // latency after the real unlock, and a decision made in that gap would otherwise be
    // admitted as pre-unlock evidence — a post-unlock blocked query could falsely satisfy
    // the QA gate's direct-evidence criterion (Codex review, #381). Bounding at the last
    // observed-locked instant under-counts the (last-observation, unlock] sliver instead:
    // fail-safe for the gate, which may under-report and rerun but never fabricate.
    // Shares the flag's confinement story: boot writes precede readPackets, steady-state
    // writes run on dnsStateQueue.
    var lastObservedLockedSharedContentAt: Date?

    // Single source of truth for session and pause state, shared with the app
    // and the intents process via the same app-group keys.
    lazy var protectionSessionStore = ProtectionSessionStore(
        storage: ProtectionUserDefaultsStorage(defaults: protectionPauseDefaults),
        lock: ProtectionNSLock()
    )

    lazy var protectionPauseStore = ProtectionPauseStore(
        storage: ProtectionUserDefaultsStorage(defaults: protectionPauseDefaults),
        lock: ProtectionNSLock()
    )

    // From Provider/PacketTunnelProvider+ChainedDataPath.swift:

    /// The one chained runtime this lifecycle owns, `dnsStateQueue`-confined like the latch.
    ///
    /// A `var` recreated per start and nilled in the teardown funnel — NetworkExtension
    /// reuses provider instances across `startTunnel`, and a `lazy` here would be
    /// per-PROVIDER, the exact class of bug the latch and the path monitor both record.
    /// Written via `dnsStateQueue.sync` from `startTunnel`'s prologue (off-queue, the same
    /// argument as the latch write) and nilled inside the teardown funnel's
    /// `dnsStateQueue.async` phase; read by the path handler (already on-queue), by
    /// `sleep`/`wake` (inside their own `dnsStateQueue.async` blocks), and by
    /// the token-validating observation submission (dual-entry, from the resolution
    /// paths).
    /// `readPackets` deliberately never reads it: the driver is CAPTURED into the read
    /// loop at arm time, so a stale loop from a previous lifecycle cannot feed a new
    /// lifecycle's driver — and the observation submission enforces the same isolation
    /// the opposite way around: it reads the driver only INSIDE its token-validating
    /// critical section, at report time, so a resolution that outlives its lifecycle
    /// has stale tokens and its report is dropped entirely — it can reach neither the
    /// next lifecycle's accumulation nor a driver whose lifecycle already ended.
    var chainedRuntime: ChainedTunnelRuntime?
    #if DEBUG || LAVA_QA_TOOLS
    // Never persisted: a provider replacement always starts without an injected outage.
    let qaPeerBlackout = ChainedQAPeerBlackout()
    #endif

    /// The F4 claimed-destination box handed to the live chained runtime's factory, owned here
    /// so `reapplyTunnelNetworkSettings` can republish it when the route plan's capture-floor
    /// routes are rebuilt. `dnsStateQueue`-confined like ``chainedRuntime``: written in
    /// `buildChainedRuntimeIfLatched`'s publish block, updated on reapply (already on-queue),
    /// and nilled in the teardown funnel. Nil for a DNS-only session.
    ///
    /// A BOX rather than a value, because the runner reads it once per packet: the session's
    /// factory is built once per lifecycle, but the resolver capture changes with the network,
    /// so a value copied at construction would classify against stale destinations after a roam
    /// (F4's whole boundary; see ``ChainedClaimedResolverDestinationsStore``).
    var chainedClaimedResolverDestinations: ChainedClaimedResolverDestinationsStore?
}
