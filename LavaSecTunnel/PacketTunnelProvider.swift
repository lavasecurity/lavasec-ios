@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecCore

// MARK: - Completion & helper types

private struct TunnelCompletion: @unchecked Sendable {
    let handler: () -> Void

    func complete() {
        handler()
    }
}

private struct AppMessageCompletion: @unchecked Sendable {
    let handler: ((Data?) -> Void)?
    let latencySpan: LatencySpan?

    init(handler: ((Data?) -> Void)?, latencySpan: LatencySpan? = nil) {
        self.handler = handler
        self.latencySpan = latencySpan
    }

    func complete(_ response: Data?) {
        latencySpan?.end(details: ["status": response == nil ? "nil-reply" : "reply"])
        handler?(response)
    }
}

private final class ResolverWorkCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: () -> Void
    private var didComplete = false

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func complete() {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }

        didComplete = true
        lock.unlock()
        handler()
    }
}

private final class ResolverSmokeProbeTimeout: @unchecked Sendable {
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

private enum ResolverQueryPurpose: Sendable {
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

private let dnsStateQueueSpecificKey = DispatchSpecificKey<Bool>()

@_silgen_name("LavaSecCopySystemDNSServers")
private func LavaSecCopySystemDNSServers(_ buffer: UnsafeMutablePointer<CChar>, _ bufferLength: Int32) -> Int32

private struct ResolverAdjustedRuntimeSnapshot: FilterRuntimeSnapshot {
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

    func decision(for rawDomain: String) -> FilterDecision {
        base.decision(for: rawDomain)
    }

    func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        base.decision(forNormalizedDomain: normalizedDomain)
    }
}

private struct FailClosedRuntimeSnapshot: FilterRuntimeSnapshot {
    let resolver: DNSResolverPreset

    var blockRuleCount: Int { 0 }
    var allowRuleCount: Int { 0 }
    var guardrailRuleCount: Int { 0 }

    // Blocks EVERY domain because no usable rule snapshot is resident. The reason is
    // `.protectionUnavailable` (NOT `.blocklist`): these are precautionary fail-closed
    // blocks, not curated matches, so labelling them `.blocklist` would forge a blocklist
    // verdict for legitimate domains (the false positives that filled the Blocked tab with
    // google.com / icloud / apple endpoints during fail-closed windows). The honest reason
    // propagates to Domain History (where DiagnosticsStore drops it), bug reports, and CSV
    // export.
    func decision(for rawDomain: String) -> FilterDecision {
        FilterDecision(action: .block, reason: .protectionUnavailable)
    }

    func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        FilterDecision(action: .block, reason: .protectionUnavailable)
    }
}

private struct TunnelNetworkSettingsBundle {
    let settings: NEPacketTunnelNetworkSettings
    let tunnelAddress: String
    let dnsServerAddress: String
    let routeDescription: String
}

private struct NetworkPathUpdate: Sendable {
    let kind: TunnelNetworkKind
    let isSatisfied: Bool
    let statusDescription: String
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private static let tunnelAddress = "10.255.0.2"
    private static let tunnelDNSServerAddress = "10.255.0.1"
    private static let tunnelRouteDescription = "10.255.0.0/24"
    private static let deviceDNSCaptureBufferLength = 1024
    private var snapshot: any FilterRuntimeSnapshot = FilterSnapshot(blockRules: DomainRuleSet())
    private var protectionPolicySnapshot: any FilterRuntimeSnapshot = FilterSnapshot(blockRules: DomainRuleSet())
    // Identity of the rule artifact currently resident in `snapshot` (nil for
    // the empty bootstrap and fail-closed snapshots). Guarded by snapshotQueue.
    // A live reload reads this to skip decoding an on-disk artifact that would
    // reproduce the resident snapshot — avoiding the 2x-resident memory peak
    // that jetsams the extension on large multi-list snapshots.
    private var residentSnapshotIdentity: PreparedFilterSnapshotIdentity?
    // True while the resident snapshot is a FailClosedRuntimeSnapshot installed because
    // NO usable snapshot could be loaded/compiled (over budget, or a build failure such
    // as a blocklist whose upstream rotated past the catalog's pinned hash) — as opposed
    // to a transient DNS wedge. A snapshot-unavailable fail-closed blocks all DNS, so the
    // smoke probe always fails; restarting the extension cannot rebuild a missing
    // snapshot, so self-reconnect must NOT escalate (it only flickers the VPN). Guarded by
    // `snapshotQueue` alongside `residentSnapshotIdentity`.
    private var residentFailClosedDueToUnavailableSnapshot = false
    // True when the resident identity-bearing snapshot was compiled from a config with
    // at least one enabled blocklist (a genuine FILTERING snapshot), false when it is the
    // permissive pass-through built for an empty config. `loadCompiledSnapshot` returns a
    // non-nil identity for BOTH (the empty config yields `(baseSnapshot, expectedIdentity)`),
    // so identity alone can't tell them apart. The keep-last-known-good path reads this to
    // refuse degrading to a pass-through resident when the new config wants filtering —
    // keeping the pass-through would silently fail OPEN. Guarded by `snapshotQueue`
    // alongside `residentSnapshotIdentity`; only meaningful while identity is non-nil
    // (fail-closed commits set identity nil and leave this at its default false).
    private var residentSnapshotHasEnabledFilters = false
    private let snapshotQueue = DispatchQueue(label: "com.lavasec.tunnel.snapshot", qos: .utility)
    private let blockedTTL: UInt32 = 1
    private let pausedWouldBlockForwardTTL: UInt32 = 1
    private static let maxConcurrentResolverQueries = 8
    private let resolverQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver", qos: .utility, attributes: .concurrent)
    private let resolverSmokeProbeQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver.smoke-probe", qos: .utility)
    // CON-4: resolver work is bounded to maxConcurrentResolverQueries WITHOUT parking a
    // thread per waiter. A serial admission queue confines the FIFO+activeCount bookkeeping
    // (BoundedWorkAdmission); over-bound submissions wait inert in the FIFO instead of a
    // blocked DispatchSemaphore.wait() (which parked one libdispatch worker per waiting query
    // — an outage burst could accumulate toward the constrained-pool cap). Admitted work is
    // dispatched to the concurrent resolverQueue exactly as before; the observable bound is
    // identical.
    private let resolverAdmissionQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver.admission", qos: .utility)
    private let resolverConcurrencyAdmission = BoundedWorkAdmission<@Sendable () -> Void>(
        bound: PacketTunnelProvider.maxConcurrentResolverQueries
    )
    private let protectionPauseStateQueue = DispatchQueue(label: "com.lavasec.tunnel.protection-pause-state", qos: .utility)
    private let dnsStateQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.lavasec.tunnel.dns-state", qos: .utility)
        queue.setSpecific(key: dnsStateQueueSpecificKey, value: true)
        return queue
    }()
    private static let udpDNSTimeoutSeconds = 1
    private static let tcpDNSTimeoutSeconds = 2
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
    // configuration-changed) keeps the routine timeout.
    private static let recoveryContextProbeReasons: Set<String> = [
        "network-settled",
        "resolver-wedge-recovery",
        "device-dns-fallback-recovery"
    ]
    // The short recovery timeout is only SAFE for the fast, UDP-based device/plain
    // primary path with no fallback branch to cut short:
    //  - An encrypted primary (DoH/DoT/DoQ) can't even return before its 5s
    //    transport timeout, so 3s would always declare a spurious failure.
    //  - A fallback-capable probe runs primary THEN device-DNS fallback; cutting at
    //    3s completes with fallbackResult=nil and the failure branch would
    //    DEACTIVATE a working device-DNS fallback while the primary is still down
    //    (P1, flagged in review). Those keep the routine timeout.
    private static func smokeProbeTimeoutSeconds(
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
    private static let slowUpstreamResponseThresholdMilliseconds = 2_500
    private let resolverBackoffStateQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver-backoff", qos: .utility)
    // Recreated per lifecycle in `startPathMonitor` (hence `var`): a cancelled
    // NWPathMonitor delivers ZERO updates when restarted, so reusing one object
    // across a same-instance stop/start (manual toggle, or a
    // setTunnelNetworkSettings-error retry) would leave handleNetworkPathUpdate
    // permanently silent — no network-change reset, no settle probe, no
    // device-DNS recapture (field-confirmed 2026-06-22). A fresh monitor each
    // start guarantees the handler can fire again.
    private var pathMonitor = Network.NWPathMonitor()
    private static let resolverSmokeProbeInterval: TimeInterval = DeviceDNSFallbackPolicy.routineSmokeProbeInterval
    // How often the always-on tunnel checks for a Focus-committed config change (LAV-100 Phase 4 P4d). A
    // closed-app Focus switch is enforced within this window; short enough to feel prompt, long enough that
    // a cheap config-generation read per minute is negligible.
    private static let focusConfigurationPollInterval: TimeInterval = 60
    // Fast recovery cadence for a same-network resolver wedge. Far shorter than
    // the 300s routine probe: when DNS is failed-closed, the user is offline now,
    // so re-probe (after clearing the backoff penalty box) until it recovers. One
    // re-probe per interval — not per query — so it never reintroduces the
    // dead-resolver hammering the backoff exists to prevent. The cadence escalates
    // from a tight first probe (LAV-92 "fast guide") and doubles up to the legacy
    // 30s ceiling, so a brief blip recovers in seconds while a sustained wedge
    // backs off to the gentle steady-state interval (== the old flat behaviour).
    private let resolverWedgeRecoveryCadence = ResolverWedgeRecoveryCadence()
    // Zero-based count of consecutive re-probes in the current wedge episode; drives
    // the escalating cadence above and resets to 0 when the probe is cancelled
    // (recovery or lifecycle reset). dnsStateQueue-confined, like the work item.
    private var resolverWedgeRecoveryAttempt = 0
    // Absolute fire deadline of the currently-armed probe (nil = none armed) and whether it was
    // armed on the gentle COVERED cadence. The scheduler preempts a pending probe when the cadence
    // MODE changed (covered<->uncovered — re-evaluate for online-vs-offline) OR a strictly-sooner
    // probe is now warranted within the same mode. dnsStateQueue-confined; armedCovered is only read
    // while armedDeadline != nil.
    private var resolverWedgeRecoveryArmedDeadline: Date?
    private var resolverWedgeRecoveryArmedCovered = false
    private let healthWriteInterval: TimeInterval = 30
    private let diagnosticsWriteInterval: TimeInterval = 30
    private let configurationRefreshInterval: TimeInterval = 30
    private let protectionPauseStateRefreshInterval: TimeInterval = 1
    // dnsStateQueue-confined, like the dictionaries they replaced.
    private let dnsResponseCache = DNSResponseCache()
    private let inFlightQueryCoalescer = InFlightDNSQueryCoalescer<PendingDNSResponse>()
    // Transient-bootstrap wait STATE machine extracted to TransientBootstrapDNSWait
    // (Phase E2). The INV-DNS-2 bounds (64-deep / 4 s) and the generation/expired-
    // generation transitions are executable there (TransientBootstrapDNSWaitTests);
    // the provider keeps the SERVFAIL writes, the replay through the filter, the
    // device-log events, and lifecycle-generation ownership (generations are passed
    // in per call, the machine never reads tunnel state). dnsStateQueue-confined,
    // with the one-shot timeout armed on the same queue.
    private lazy var transientBootstrapDNSWait = TransientBootstrapDNSWait<PendingDNSResponse>(
        queue: dnsStateQueue,
        scheduleAfter: { [dnsStateQueue] interval, body in
            let item = DispatchWorkItem(block: body)
            dnsStateQueue.asyncAfter(deadline: .now() + interval, execute: item)
            return item
        }
    )
    private var resolverBackoffPolicy = ResolverBackoffPolicy()
    private var health = TunnelHealthSnapshot()
    private var diagnostics = DiagnosticsStore()
    private var appConfiguration = AppConfiguration()
    private var deviceDNSResolverAddresses: [String] = []
    private var deviceDNSFallbackModeActive = false
    private var consecutiveQueryFallbackSuccessCount = 0
    // Coalesce the per-query `dns-encrypted-fallback` debug marker. A wedged Device-DNS
    // primary routes EVERY organic query to the encrypted (Mullvad DoH) fallback, so a
    // per-query log floods the debug ring (~1.6k lines in a 6h flaky-network export,
    // evicting more useful events) for zero added signal. Log the first carried query of
    // an episode immediately, then throttle to one marker per interval carrying the count
    // since the last marker — that count preserves "how often the safety net saved a
    // wedge" without the spam. Reset on recovery so each new episode logs its first query.
    private var encryptedFallbackCarriedSinceLastLog = 0
    private var lastEncryptedFallbackLogAt: Date?
    private let encryptedFallbackLogThrottleInterval: TimeInterval = 60
    // Consecutive REAL client-query total failures (primary AND every fallback leg
    // failed) since the last carried success. Deliberately separate from
    // health.consecutiveUpstreamFailureCount, which a failed PRIMARY smoke probe also
    // bumps (applyResolverSmokeProbeResult) — that pollution would let a lone forwarding
    // transient, layered on a smoke-inflated count, tear down encrypted-fallback coverage.
    // This forwarding-only streak gates the coverage teardown so only a SUSTAINED
    // carried-query outage (a genuinely dead DoH/DoT leg) clears the serving timestamp.
    private var consecutiveCarriedQueryFailureCount = 0
    /// Consecutive carried-query failures that mark the encrypted fallback as no longer
    /// serving. Matched to the policy reconnect threshold so a dead fallback loses coverage
    /// on the same "sustained, not transient" scale; the policy's 30s coverage freshness
    /// window is the independent backstop when carried traffic is too sparse to reach this.
    private let encryptedFallbackCoverageClearFailureThreshold = 3
    private var resolverSmokeProbeGeneration = 0
    private var resolverSmokeProbeTimer: DispatchSourceTimer?
    // NRG-3a (founder-approved 2026-07-02): acceptance-checked primary evidence lets the
    // PERIODIC probe skip its wire query — the 300s cadence itself is the honesty budget
    // and stays untouched; only the redundant radio wake is saved. Stamped by an ACCEPTED
    // primary smoke probe or an organic primary answer passing the SAME acceptance check
    // the probe applies (NOERROR + answers). Deliberately NOT lastPrimaryUpstreamSuccessAt:
    // that field is stamped by any reply that merely resolved — including a hijacking
    // resolver's REFUSED/SERVFAIL — and the LAV-87 streak advances only via probes, so a
    // resolved-only gate would let a hijacker suppress routine probes indefinitely.
    // In-memory only (a restart re-proves) and cleared on every resolver-runtime reset,
    // so evidence can never outlive the runtime (or primary identity) it was observed under.
    // dnsStateQueue-confined.
    private var lastAcceptedPrimaryEvidenceAt: Date?
    // LAV-100 Phase 4 P4d: dedicated poll that adopts a Focus-committed filter switch made by the App
    // Intents extension while the app is closed. The extension can't push to the tunnel (sendProviderMessage
    // is app-only) and a tunnel-side Darwin observer was proven unreliable in the NE extension (0 callbacks /
    // 14 device probes — see PacketTunnelDNSRuntimeSourceTests), so the always-on tunnel POLLS the on-disk
    // configuration generation and reloads through the existing path when it advances. dnsStateQueue-confined.
    // Timer mechanism extracted to QueueConfinedRepeatingTimer (Phase E2); poll
    // POLICY (interval, tick, watermark rules) stays here with its pins.
    private lazy var focusConfigurationPollTimer = QueueConfinedRepeatingTimer(queue: dnsStateQueue)
    private var lastObservedConfigurationGeneration = 0
    private var protectionPauseResumeTimer: DispatchSourceTimer?
    private var snapshotReloadGeneration: UInt64 = 0
    // dnsStateQueue-confined: true while the LATEST-requested snapshot reload is still running. The Focus
    // config poll checks it and SKIPS a tick rather than calling requestSnapshotReload again — re-requesting
    // would bump `snapshotReloadGeneration` and invalidate the in-flight load (and reset the DNS runtime), so
    // a load/compile slower than the poll interval would be restarted forever and never adopt (Codex round 5).
    // Set at the single reload chokepoint (`nextSnapshotReloadGeneration`), cleared when the load resolves
    // (generation-gated, so an overlapping newer load keeps ownership) and on an explicit invalidation.
    private var snapshotReloadInFlight = false
    // CON-3: single-flights the in-extension snapshot compile so two overlapping reloads (a first-start
    // compile still running when a pull-to-refresh requests another) can never hold two ~32 MiB compile
    // peaks resident at once — ≈60 MiB in the 50 MB-limited NE process would jetsam the tunnel mid-serve.
    // The generation only fences the COMMIT; this gate serializes the peak itself. Wraps ONLY the compile
    // step in loadCompiledSnapshot (the cheap header reads stay concurrent), and the caller re-checks the
    // reload generation immediately before entering it so a superseded reload skips the compile entirely.
    private let snapshotCompileGate = SnapshotCompileGate()
    private var lastAppliedTemporaryProtectionPauseIsActive = false
    // dnsStateQueue-confined: marks the first DNS decision after tunnel start so
    // the "first DNS after start" latency target is measurable end to end.
    private var hasRecordedFirstDNSDecision = false
    private var firstDNSDecisionReferenceAt: Date?
    private var tunnelStartLatencyOperationID: LatencyOperationID?
    private var fallbackRecoverySmokeProbeWorkItem: DispatchWorkItem?
    // Pending same-network wedge-recovery re-probe (backoff reset + smoke probe),
    // scheduled while DNS is wedged and cancelled the moment it recovers.
    private var resolverWedgeRecoveryWorkItem: DispatchWorkItem?
    // Pending bounded device-DNS capture retry (dns-recovery optimization C),
    // armed after a handoff/wake while the in-tunnel capture keeps coming back
    // empty (masked) and superseded on the next network change / wake / reset.
    // Cycle STATE machine extracted to DeviceDNSCaptureRetryCycle (Phase E2, after the
    // rc5 field log showed the wake-suppression cooldown being bypassed — see
    // DeviceDNSCaptureRetryCycleTests). The provider keeps the capture WORK.
    private lazy var deviceDNSCaptureRetryCycle = DeviceDNSCaptureRetryCycle(
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
    private var networkKind: TunnelNetworkKind = .unknown
    private var lastConfigurationRefreshAt = Date.distantPast
    private var lastProtectionPauseStateRefreshAt = Date.distantPast
    private var cachedTemporaryProtectionPauseUntil: Date?
    private var lastConfigurationModifiedAt: Date?
    private var lastDiagnosticsControlModifiedAt: Date?
    // PST-1: the "already applied this clear request" markers are no longer in-memory
    // ivars (nil in every fresh process → the force-apply on every start re-wiped all
    // post-clear data). They now live durably on the diagnostics store itself
    // (`lastAppliedDomainHistoryClearAt` / `lastAppliedFilteringCountsClearAt`), written
    // in the same file the clear mutates.
    // Health and diagnostics share one debounced dirty-flush persistence machine
    // (extracted to LavaSecCore; replaces the two byte-for-byte-identical inline
    // copies that were the disk-churn class behind the 2026-06-14 heat regression).
    // Stateless scheduler → one instance serves both controllers; each owns its
    // own pending token. dnsStateQueue-confined, like the inline state it replaces.
    private lazy var persistenceFlushScheduler = DispatchSettleWorkScheduler(queue: dnsStateQueue)
    private lazy var healthPersistence = DebouncedPersistenceController(
        writeInterval: healthWriteInterval,
        scheduler: persistenceFlushScheduler,
        write: { [weak self] _ in
            guard let self, let containerURL = LavaSecAppGroup.containerURL else {
                return false
            }
            let url = containerURL.appendingPathComponent(LavaSecAppGroup.tunnelHealthFilename)
            guard let data = try? JSONEncoder().encode(self.health) else {
                return false
            }
            try? data.write(to: url, options: Data.WritingOptions.atomic)
            return true
        }
    )
    private lazy var diagnosticsPersistence = DebouncedPersistenceController(
        writeInterval: diagnosticsWriteInterval,
        scheduler: persistenceFlushScheduler,
        write: { [weak self] now in
            guard let self else {
                return false
            }
            self.diagnostics.resetForCurrentDayIfNeeded(now: now)
            guard let diagnosticsURL = self.diagnosticsURL else {
                return false
            }
            try? DiagnosticsPersistence.save(self.diagnostics, to: diagnosticsURL)
            return true
        }
    )
    private let dohResolver = DoHTransport(timeoutSeconds: PacketTunnelProvider.dohTimeoutSeconds) { event, details in
        LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
    }
    private let dotResolver = DoTTransport(timeoutSeconds: PacketTunnelProvider.dotTimeoutSeconds) { event, details in
        LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
    }
    private let doqResolver = DoQTransport(timeoutSeconds: PacketTunnelProvider.doqTimeoutSeconds) { event, details in
        #if DEBUG || LAVA_QA_TOOLS
        if event == "dns-doq-connection-ready" {
            // NRG DoQ lever: count the fresh QUIC handshake + its duration atomically
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
    private let resolverLatencyOperationID = LatencyOperationID.make()
    // Memo of `DomainName.normalize` for resolver endpoint hostnames. normalize is pure and
    // deterministic (same input → same output), and the set of resolver hostnames is tiny and
    // stable for a resolver runtime. The memo is still runtime-scoped and capped so a future
    // dynamic caller cannot retain unbounded hostnames in a long-running extension process.
    // The bootstrap checks run first on EVERY DNS packet — including cache hits — and previously
    // re-normalized each candidate endpoint host per query (≈2–5 normalize calls/packet, each
    // doing IDNA/split/map allocations). This collapses the steady state to a dict lookup.
    // Thread-safe: read primarily from the serial packet callback queue, the lock is defensive
    // against any off-queue caller.
    private static let endpointHostnameNormalizationCacheLimit = 32
    private let endpointHostnameNormalizationCacheLock = NSLock()
    private var endpointHostnameNormalizationCache: [String: String] = [:]
    private var activeResolverRuntimeIdentifier: String?
    // The PRIMARY-resolver identity of the active runtime (no fallback/encrypted-fallback/mode
    // components). The DNS-health-context boundary (smokeProbeContextBaseline) and the rejected
    // streak are about the PRIMARY, so they advance/clear only when THIS changes — never on a
    // fallback-only runtime reset (encrypted-fallback resolver change, device-DNS fallback toggle).
    private var activeResolverPrimaryIdentifier: String?
    private var resolverRuntimeGeneration = 0
    private var tunnelLifecycleGeneration: UInt64 = 0
    private var lastObservedPathKind: TunnelNetworkKind?
    private var lastObservedPathIsSatisfied: Bool?
    // Freshest path-satisfied state the monitor has delivered, stamped SYNCHRONOUSLY
    // in the pathUpdateHandler — one dnsStateQueue hop earlier than
    // `health.networkPathIsSatisfied`, which handleNetworkPathUpdate applies via a
    // SECOND deferred hop. The self-reconnect teardown guard reads this so a path
    // update that has been delivered but whose deferred mutation hasn't landed yet
    // can't be missed (the cancel-into-dead-network race). Optimistic default (true)
    // matches "no adverse path info yet".
    private var latestMonitoredPathIsSatisfied = true
    private var lastNetworkSettingsReapplyAt = Date.distantPast
    private let reconnectNeededActivityReminderInterval: TimeInterval = 300
    private var lastReconnectNeededActivityAt: Date?
    // When the current reconnect-needed wedge *began* (set once on entry, cleared
    // on recovery). Distinct from lastReconnectNeededActivityAt, which refreshes on
    // When the current reconnect-needed wedge *began* (set once on entry, cleared
    // only when a recovery is actually logged or on a tunnel-lifecycle reset).
    // Deliberately NOT cleared by clearReconnectNeededActivitySuppression: a
    // network change routes through that clear before the network-settled probe
    // recovers, and wiping the marker there would make the handoff recovery (a
    // primary path this logging targets) silently no-op. Distinct from
    // lastReconnectNeededActivityAt (300s notify throttle) and lastUpstreamFailureAt
    // (refreshes on every failed query), so a recovery reports the true wedge
    // duration, not the gap since the last failed lookup.
    private var reconnectNeededSince: Date?
    private var reconnectNeededReason: String?
    // Peak consecutive-upstream-failure count seen during the current wedge.
    // Captured on the marker because the success paths reset
    // health.consecutiveUpstreamFailureCount to 0 before logging recovery, so the
    // exported dns-recovered would otherwise lose how many failures the wedge
    // accumulated (orthogonal to duration: few failures over a long idle wedge vs.
    // many under heavy browsing). max() preserves it across a network-change reset.
    private var reconnectNeededPeakFailureCount = 0
    // Last-resort recovery: when DNS stays wedged after a handoff (device-DNS
    // resolvers can't be re-captured while the tunnel is active), restart the
    // tunnel so startup re-captures them. Latched so we issue the cancel once, and
    // the attempt history is persisted (the cancel kills this process) for the
    // cross-restart backoff in TunnelSelfReconnectPolicy.
    private var hasRequestedSelfReconnect = false
    // Set when a no-fallback device-DNS recapture restart is warranted but was
    // rate-limited (cooldown/cap). The recovery retry re-enters the wedge path
    // (selfReconnectIfPolicyAllows), which would otherwise apply the lower `.wedge`
    // ceiling and discard the intended third recapture restart until the window ages
    // out (Codex P1). This carries the `.deviceDNSRecapture` ceiling across that hop.
    // Cleared on recovery (clearReconnectNeededActivitySuppression) and on a fresh tunnel
    // lifecycle (resetHealth), so a reused provider instance can't carry it into an
    // unrelated wedge. In-memory only: a fired restart kills the process, and the next
    // launch is itself a fresh recapture.
    private var deviceDNSRecaptureRestartPending = false
    // Dedup state for the self-reconnect-suppressed device-log line. A persistent
    // wedge re-evaluates the policy on every failed query/tick, which previously
    // logged a suppressed line each time (hundreds per wedge), churning the size-
    // capped debug log and evicting useful diagnostics. We log only when the
    // suppression signature changes or after a cooldown, so the reason is still
    // captured without the storm.
    private var lastSelfReconnectSuppressionSignature: String?
    private var lastSelfReconnectSuppressionLogAt: Date?
    // Dedup state for the self-reconnect-skipped-path-unsatisfied line. While the
    // network path is unsatisfied the tunnel keeps receiving (failing) queries, so
    // the policy can re-decide .reconnect and re-skip on every one; share the same
    // cooldown the suppression line uses so a flapping handoff can't storm the log.
    private var lastSelfReconnectPathSkipLogAt: Date?
    private static let selfReconnectSuppressionLogInterval: TimeInterval = 60
    private static let selfReconnectAttemptsDefaultsKey = "tunnel.selfReconnectAttemptTimes"
    // Restart-survivable marker for the productive-recovery credit (Track 4): the wall
    // time of the last committed self-reconnect, persisted just before the cancel kills
    // the process and read on the next launch. If the relaunched tunnel reaches a
    // confirmed primary recovery within `selfReconnectCreditWindow`, the attempt that led
    // to this launch is credited back (pruned from the shared attempt store) so a genuine
    // network switch nets ~0 against the cap; a restart that never recovers keeps its
    // attempt and accrues toward the cap (a true loop is bounded, a productive one isn't).
    private static let lastSelfReconnectAtDefaultsKey = "tunnel.lastSelfReconnectAt"
    private static let selfReconnectCreditWindow: TimeInterval = 120
    // Nudges the foreground app to pull fresh health (over the provider-message
    // channel) when the connectivity-relevant state changes, so the Dynamic
    // Island reflects reconnect/network-lost states without waiting for the next
    // app-side status poll (UR-6). Darwin works app-side because the app's run
    // loop is live; the tunnel only ever POSTS — it must not re-add the dormant,
    // unreliable extension-side observer that was deliberately removed.
    private let connectivitySignalNotifier: any ProtectionSignalNotifier = DarwinProtectionSignalNotifier()
    private var lastSignaledConnectivityKey: String?
    #if LAVA_QA_TOOLS
    private var lastQAConnectivitySeverity: ProtectionConnectivitySeverity = .healthy
    private var lastQAConnectivityLogAt = Date.distantPast
    #endif

    // MARK: - Tunnel lifecycle (start / stop / wake)

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let operationID = Self.latencyOperationID(from: options)
        #if DEBUG || LAVA_QA_TOOLS
        let trace = Self.makeLatencyTrace(operationID: operationID, operationKind: "tunnelStart")
        let startSpan = trace.beginSpan("tunnel.start", details: [
            "status": "begin",
            "hasOptions": "\(options != nil)",
            "hasOperationID": "\(operationID != nil)"
        ])
        #endif

        // Stamp the build onto each tunnel session start so every captured event
        // is attributable to an exact app version / build / source commit — a
        // single local-log export can span an app update. The extension reads its
        // own Info.plist (MARKETING_VERSION / CURRENT_PROJECT_VERSION, and
        // LavaSourceRevision injected at release time; empty for local builds).
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "startTunnel-begin", details: [
            "hasOptions": "\(options != nil)",
            "hasOperationID": "\(operationID != nil)",
            "appVersion": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
            "appBuild": (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "",
            "sourceRevision": (Bundle.main.object(forInfoDictionaryKey: "LavaSourceRevision") as? String) ?? ""
        ])

        let completion = SendableCompletion(completionHandler)
        let lifecycleGeneration = beginTunnelLifecycle(reason: "startTunnel")
        beginFreshProtectionVPNSession(reason: "startTunnel")
        let shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings = loadInitialSharedState()
        scheduleProtectionPauseResumeIfNeeded(reason: "startTunnel")
        refreshDeviceDNSResolverAddresses(reason: "startTunnel")
        resetHealth()
        resetResolverRuntimeForTunnelLifecycle(reason: "startTunnel")
        startPathMonitor()

        let settingsBundle = makeTunnelNetworkSettingsForCurrentConfiguration()

        let settingsStartedAt = Date()
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-begin", details: [
            "tunnelAddress": settingsBundle.tunnelAddress,
            "dnsServerAddress": settingsBundle.dnsServerAddress,
            "route": settingsBundle.routeDescription
        ])
        #if DEBUG || LAVA_QA_TOOLS
        let networkSettingsSpan = trace.beginSpan("tunnel.setNetworkSettings", parent: startSpan, details: [
            "status": "begin"
        ])
        #endif

        setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in
            guard let self else {
                #if DEBUG || LAVA_QA_TOOLS
                networkSettingsSpan.end(details: ["status": "missing-provider"])
                startSpan.end(details: ["status": "missing-provider"])
                #endif
                completion(error)
                return
            }

            if let error {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-error", details: Self.errorDebugDetails(error))
                #if DEBUG || LAVA_QA_TOOLS
                networkSettingsSpan.end(details: ["status": "error", "errorKind": "\(type(of: error))"])
                startSpan.end(details: ["status": "error", "errorKind": "\(type(of: error))"])
                #endif
                self.cleanUpTunnelRuntimeAfterFailedStart(reason: "setTunnelNetworkSettings-error") {
                    completion(error)
                }
                return
            }

            guard self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-stale", details: [
                    "generation": "\(lifecycleGeneration)"
                ])
                #endif
                #if DEBUG || LAVA_QA_TOOLS
                networkSettingsSpan.end(details: ["status": "stale"])
                startSpan.end(details: ["status": "stale"])
                #endif
                completion(CocoaError(.userCancelled))
                return
            }

            let duration = Date().timeIntervalSince(settingsStartedAt)
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-success", details: [
                "durationMs": "\(Int((duration * 1_000).rounded()))"
            ])
            #if DEBUG || LAVA_QA_TOOLS
            networkSettingsSpan.end(details: ["status": "ok"])
            #endif

            self.markLocalProtectionUptimeStarted()
            self.dnsStateQueue.async { [weak self] in
                self?.hasRecordedFirstDNSDecision = false
                self?.firstDNSDecisionReferenceAt = Date()
                self?.tunnelStartLatencyOperationID = operationID
            }
            // Reclaim scratch a jetsam-killed prior compile orphaned — ONCE, here, before
            // any snapshot reload spawns a streaming compile. Overlapping reloads run their
            // compiles concurrently (each in its own UUID scratch dir) and only the final
            // commit is generation-gated, so a per-compile "remove every scratch dir" sweep
            // could delete a sibling's in-flight blob/output. A hard kill (the only way a
            // scratch dir is orphaned) always restarts the extension and re-runs startTunnel,
            // and a live process removes each compile's own dir via `defer`, so startup is
            // both the only place orphans appear and the only race-free place to sweep them.
            if let catalogCacheURL = self.catalogCacheURL {
                CachedFilterSnapshotCompiler.sweepStaleScratch(cacheDirectoryURL: catalogCacheURL)
            }
            if shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings {
                self.beginTransientBootstrapDNSWait(reason: "setTunnelNetworkSettings-success")
            }
            self.loadSnapshotInBackground(reason: "startTunnel", operationID: operationID)
            // Lazy vars are not thread-safe: force the resolver seams here,
            // single-threaded, before any packet or probe can race their
            // first touch.
            _ = self.resolverOrchestrator
            self.prewarmResolverBootstrapIfNeeded()
            #if DEBUG || LAVA_QA_TOOLS
            EnergyCounters.shared.activate()   // NRG: activate (synchronously) BEFORE the first "startTunnel" probe so its wire bump counts
            #endif
            self.scheduleResolverSmokeProbeIfNeeded(reason: "startTunnel")
            self.startPeriodicResolverSmokeProbe()
            self.startFocusConfigurationPoll()
            self.readPackets()
            // The gap a committed self-reconnect opened closes HERE — settings installed,
            // packets flowing — not at startTunnel entry: a relaunch whose settings install
            // fails never resumed protection, and stamping earlier would record a short,
            // closed gap for what is really a still-open outage.
            Self.closeDanglingSelfReconnectGapIfNeeded()
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "startTunnel-ready")
            #if DEBUG || LAVA_QA_TOOLS
            startSpan.end(details: ["status": "ready"])
            #endif
            completion(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        #if DEBUG || LAVA_QA_TOOLS
        // Capture the OS stop reason (raw + readable) so an unexpected,
        // system-initiated teardown — e.g. .internalError(17), which stops the
        // tunnel with no app involvement and no auto-restart — is diagnosable
        // from the log instead of appearing as a "silent" disconnect.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "stopTunnel", details: [
            "reason": "\(reason.rawValue)",
            "reasonName": Self.stopReasonName(reason)
        ])
        #endif

        let completion = TunnelCompletion(handler: completionHandler)
        invalidateTunnelLifecycle(reason: "stopTunnel")
        cleanUpTunnelRuntimeAfterStop(reason: "stopTunnel") {
            completion.complete()
        }
    }

    // iOS can suspend the extension while the device sleeps (e.g. in a pocket
    // while walking out the door) and then call wake() when it resumes. By then
    // the upstream resolver connections and bootstrapped endpoint IPs are likely
    // stale, so drop them and re-probe: refresh device DNS, force-drop cached
    // responses and tear down stale UDP sockets / DoH/DoT/DoQ connections,
    // invalidate the bootstrap cache, then schedule the resolver re-handshake once
    // the path settles. The forced reset is what keeps a query arriving before the
    // coalesced settle probe from reusing a pre-sleep connection.
    //
    // We deliberately do NOT clear the device-DNS fallback decision here. wake()
    // also fires on ordinary sleep with no network change; clearing fallback would
    // drop a fallback that is keeping DNS working (configured resolver failing on
    // this network) and force a failing-primary retry — a fresh stall every wake.
    // Real network changes are handled by handleNetworkPathUpdate (which does clear
    // fallback). Computing the reset identifier with the current mode keeps the
    // post-reset runtime consistent with what queries use; the settle probe still
    // re-checks the primary in the background and recovers if it now works.
    override func wake() {
        // Device-log appends stay un-gated so Release/TestFlight feedback reports
        // capture VPN wake events (privacy-audited: no event records a queried
        // domain). #21 shipped this in Release; do not re-wrap in #if DEBUG.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "wake")
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            // Invalidate any smoke probe already in flight (regular or
            // fallback-recovery) so a result computed before sleep can't apply
            // after resume and flip the fallback decision on stale, pre-sleep
            // network conditions — without itself clearing fallback.
            self.invalidateInFlightSmokeProbes()
            self.refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "wake")
            let resolverIdentifier = self.currentResolverRuntimeConfiguration().cacheIdentifier
            let pendingResponses = self.collectPendingResponsesAndResetResolverRuntime(
                identifier: resolverIdentifier,
                reason: "wake",
                force: true
            )
            self.resolverBootstrapService.invalidateAll()
            self.writeServerFailures(for: pendingResponses, reason: "wake")
            self.resolverProbeCoalescer.noteUnsettled()
            // The pre-sleep capture is likely stale (the device may have changed
            // networks while suspended); retry the read so a device-DNS user adopts
            // the current network's resolvers without waiting on a restart.
            self.scheduleDeviceDNSCaptureRetryIfNeeded(reason: "wake")
        }
    }

    #if DEBUG || LAVA_QA_TOOLS
    private static func stopReasonName(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: return "none"
        case .userInitiated: return "userInitiated"
        case .providerFailed: return "providerFailed"
        case .noNetworkAvailable: return "noNetworkAvailable"
        case .unrecoverableNetworkChange: return "unrecoverableNetworkChange"
        case .providerDisabled: return "providerDisabled"
        case .authenticationCanceled: return "authenticationCanceled"
        case .configurationFailed: return "configurationFailed"
        case .idleTimeout: return "idleTimeout"
        case .configurationDisabled: return "configurationDisabled"
        case .configurationRemoved: return "configurationRemoved"
        case .superceded: return "superceded"
        case .userLogout: return "userLogout"
        case .userSwitch: return "userSwitch"
        case .connectionFailed: return "connectionFailed"
        case .sleep: return "sleep"
        case .appUpdate: return "appUpdate"
        default:
            // .internalError = 17 (iOS 18.1+, "an internal error occurred in the
            // NetworkExtension framework"). Matched by raw value to stay
            // build-safe below the availability floor.
            return reason.rawValue == 17 ? "internalError" : "unknown(\(reason.rawValue))"
        }
    }
    #endif

    private func beginTunnelLifecycle(reason: String) -> UInt64 {
        let begin: () -> UInt64 = {
            self.tunnelLifecycleGeneration += 1
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "lifecycle-begin", details: [
                "reason": reason,
                "generation": "\(self.tunnelLifecycleGeneration)"
            ])
            #endif
            return self.tunnelLifecycleGeneration
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return begin()
        }

        return dnsStateQueue.sync(execute: begin)
    }

    private func invalidateTunnelLifecycle(reason: String) {
        let invalidate = {
            self.tunnelLifecycleGeneration += 1
            self.cancelTransientBootstrapDNSWait(reason: "lifecycle-invalidated-\(reason)")
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "lifecycle-invalidated", details: [
                "reason": reason,
                "generation": "\(self.tunnelLifecycleGeneration)"
            ])
            #endif
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            invalidate()
            return
        }

        dnsStateQueue.sync(execute: invalidate)
    }

    private func isCurrentTunnelLifecycle(_ generation: UInt64) -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return generation == tunnelLifecycleGeneration
        }

        return dnsStateQueue.sync {
            generation == tunnelLifecycleGeneration
        }
    }

    private func cleanUpTunnelRuntimeAfterFailedStart(reason: String, completion: @escaping @Sendable () -> Void) {
        invalidateTunnelLifecycle(reason: reason)
        cleanUpTunnelRuntimeAfterStop(reason: reason, completion: completion)
    }

    private func cleanUpTunnelRuntimeAfterStop(reason: String, completion: @escaping @Sendable () -> Void) {
        pathMonitor.cancel()
        dohResolver.cancel()
        dotResolver.cancel()
        doqResolver.cancel()
        stopPeriodicResolverSmokeProbe()
        stopFocusConfigurationPoll()
        cancelProtectionPauseResumeTimer()
        endProtectionVPNSession(reason: reason)
        cancelFallbackRecoverySmokeProbe()
        cancelResolverWedgeRecoveryProbe()
        cancelDeviceDNSCaptureRetry()

        dnsStateQueue.async { [weak self] in
            guard let self else {
                completion()
                return
            }

            // Cancel the pending coalesced settle probe here, on dnsStateQueue: the
            // coalescer is queue-confined (not Sendable), so it can't be cancelled
            // with the off-queue cancels above. A stop/failed-start within the
            // ~1.5s settle window would otherwise leave one live timer that runs
            // resolver work after teardown.
            self.resolverProbeCoalescer.cancel()
            self.invalidateSnapshotReloadGeneration(reason: reason)
            self.diagnostics.stopLocalProtectionUptime()
            self.markDiagnosticsUpdated()
            self.persistHealthIfNeeded(force: true)
            self.persistDiagnosticsIfNeeded(force: true)
            completion()
        }
    }

    private static func errorDebugDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "errorDescription": nsError.localizedDescription,
            "errorDomain": nsError.domain,
            "errorCode": "\(nsError.code)",
            "underlyingError": "\(nsError.userInfo[NSUnderlyingErrorKey] ?? "nil")"
        ]
    }

    // phys_footprint is the dirty + compressed memory iOS charges against the
    // packet-tunnel jetsam limit (mapped/clean file pages are excluded), so it
    // is the right gauge for the snapshot memory budget and for verifying the
    // zero-copy mmap of the domain table.
    private static func currentMemoryFootprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return "unknown"
        }
        return String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)
    }

    private static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    private func makeTunnelNetworkSettingsForCurrentConfiguration() -> TunnelNetworkSettingsBundle {
        Self.makeTunnelNetworkSettings()
    }

    private static func makeTunnelNetworkSettings() -> TunnelNetworkSettingsBundle {
        let tunnelAddress = Self.tunnelAddress
        let dnsServerAddress = Self.tunnelDNSServerAddress
        let routeDescription = Self.tunnelRouteDescription
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: dnsServerAddress)
        settings.mtu = 1280

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.0.0", subnetMask: "255.255.255.0")]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: [dnsServerAddress])
        dns.matchDomains = [""]
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Keep DNS inside Lava's packet tunnel; Lava performs resolver fallback after local filtering.
            dns.allowFailover = false
        }
        #endif
        settings.dnsSettings = dns

        return TunnelNetworkSettingsBundle(
            settings: settings,
            tunnelAddress: tunnelAddress,
            dnsServerAddress: dnsServerAddress,
            routeDescription: routeDescription
        )
    }

    // MARK: - App messaging (IPC)

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let providerMessage = LavaSecProviderMessageCodec.decode(messageData) else {
            let completion = AppMessageCompletion(handler: completionHandler)
            completion.complete(nil)
            return
        }

        let message = providerMessage.kind
        #if DEBUG || LAVA_QA_TOOLS
        let trace = providerMessage.operationID.map { operationID in
            LatencyTrace(
                operationID: LatencyOperationID(rawValue: operationID),
                sink: LatencyDebugLogEventSink(operationKind: "providerMessage") { event, details in
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
                }
            )
        }
        trace?.record("provider.message.received", details: ["kind": message])
        let completion = AppMessageCompletion(
            handler: completionHandler,
            latencySpan: trace?.beginSpan("provider.message.reply", details: ["kind": message])
        )
        #else
        let completion = AppMessageCompletion(handler: completionHandler)
        #endif

        switch message {
        case LavaSecAppGroup.reloadSnapshotMessage:
            requestSnapshotReload(
                reason: "appMessage",
                force: true,
                operationID: providerMessage.operationID.map(LatencyOperationID.init(rawValue:))
            )
            completion.complete(Data("ok".utf8))

        case LavaSecAppGroup.reloadProtectionPauseMessage:
            refreshProtectionPauseStateOnly(reason: "protectionPause")
            completion.complete(Data("ok".utf8))

        case LavaSecAppGroup.reloadConfigurationMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                // Always load the new config so non-resolver fields (diagnostics
                // toggles, paid status) take effect. But only reset the DNS
                // runtime and reapply tunnel network settings — a VISIBLE
                // reconnect — when the RESOLVER config actually changed. A
                // diagnostics-flag or paid-status change must never drop the
                // live connection (plan acceptance: config change does not
                // reconnect unless identity changed).
                let previousResolverIdentity = Self.resolverNetworkIdentity(self.currentAppConfiguration())
                self.refreshConfigurationIfNeeded(force: true)
                let resolverChanged = Self.resolverNetworkIdentity(self.currentAppConfiguration()) != previousResolverIdentity

                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "reload-configuration", details: [
                    "resolverChanged": "\(resolverChanged)"
                ])
                #endif

                if resolverChanged {
                    self.deviceDNSFallbackModeActive = false
                    self.consecutiveQueryFallbackSuccessCount = 0
                    self.clearEncryptedFallbackLogThrottle(phase: "context-reset")
                    self.health.deviceDNSFallbackModeActive = false
                    self.health.lastDeviceDNSFallbackActivatedAt = nil
                    self.health.consecutiveUpstreamFailureCount = 0
                    self.cancelFallbackRecoverySmokeProbe()
                    self.markHealthUpdated()
                    self.persistHealthIfNeeded(force: true)
                    self.resolverSmokeProbeGeneration += 1
                    self.replaceSnapshotResolver(self.currentAppConfiguration().resolverPreset)
                    self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                    self.reapplyTunnelNetworkSettings(reason: "configuration-changed", enforceThrottle: false)
                    self.scheduleResolverSmokeProbeIfNeeded(reason: "configuration-changed")
                }
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.clearDiagnosticsMessage, LavaSecAppGroup.clearFilteringCountsMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                // Route the clear through the SAME marker-gated control apply as the 60s poll (PST-7)
                // and the start force-apply, rather than an unconditional clearDomainHistory(clearedAt:
                // Date()) / clearFilteringCounts(). The app writes the diagnostics-control request
                // BEFORE sending this message, so this apply reads it and clears only what is strictly
                // newer than the durable applied-marker (requestedAt > lastApplied). Without this, the
                // poll could apply the clear first and THEN this handler would wipe a second time,
                // destroying any events recorded between the two — even though the request was already
                // satisfied (Codex #226). force:true bypasses only the coarse mtime pre-filter; the
                // per-request durable marker still dedups against the poll. Both clear messages are now
                // nudges to the same unified apply — the control file is the source of truth for WHAT
                // to clear, so each clear type stays independently marker-gated.
                self.applyDiagnosticsControlIfNeeded(force: true)
                self.persistDiagnosticsIfNeeded(force: true)
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.clearNetworkActivityLogMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                guard let networkActivityLogURL else {
                    completion.complete(Data("ok".utf8))
                    return
                }
                // CON-1: the clear must run on the SAME serial queue as the deferred
                // appends. Any append enqueued before this handler already sits ahead of
                // this clear on networkActivityLogIOQueue, so the wipe runs last and wins —
                // otherwise a pending append would recreate the log the user just cleared.
                // This queue is NOT drained by the terminal self-reconnect `sync`, so the
                // clear stays BLOCKING/reliable (a privacy wipe must not drop) without any
                // risk of stalling DNS or teardown (Codex #200 P2).
                Self.networkActivityLogIOQueue.async {
                    NetworkActivityLogPersistence.clear(at: networkActivityLogURL)
                    completion.complete(Data("ok".utf8))
                }
            }

        case LavaSecAppGroup.clearIncidentLedgerMessage:
            guard let containerURL = LavaSecAppGroup.containerURL else {
                completion.complete(Data("ok".utf8))
                return
            }
            let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
            // Same ordering discipline as clearNetworkActivityLogMessage (CON-1): take a
            // dnsStateQueue turn FIRST. Several recordIncident sites (wedge, rejected-probe,
            // fail-closed serve) run inside dnsStateQueue blocks; hopping straight to
            // appGroupLogIOQueue would let an already-queued DNS-state block enqueue its
            // append AFTER this clear and resurrect the ledger. Draining dnsStateQueue means
            // every such block has already enqueued its append ahead of the clear, so the
            // clear runs last on appGroupLogIOQueue and the privacy wipe wins.
            //
            // NON-BLOCKING `tryClear` (Codex #200 P2): this runs on appGroupLogIOQueue, the
            // queue the terminal self-reconnect commit drains via `sync`. A blocking clear
            // here could wait indefinitely on the ledger flock a suspended app holds (its
            // bounded sweepExpired can be suspended mid-critical-section) and stall the
            // teardown behind it. Dropping on contention is safe: the app's own direct
            // `clear` (blocking, off the teardown path) already removed the file, so at worst
            // a pre-clear append this handler just drained survives until retention ages it.
            dnsStateQueue.async { [weak self] in
                guard self != nil else {
                    completion.complete(nil)
                    return
                }
                Self.appGroupLogIOQueue.async {
                    IncidentLedgerPersistence.tryClear(at: ledgerURL)
                    completion.complete(Data("ok".utf8))
                }
            }

        case LavaSecAppGroup.flushTunnelHealthMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                self.health.networkKind = self.currentNetworkKind()
                self.health.updatedAt = Date()
                self.persistHealthIfNeeded(force: true)
                completion.complete(Data("ok".utf8))
            }

        default:
            completion.complete(nil)
        }
    }

    private static func latencyOperationID(from options: [String: NSObject]?) -> LatencyOperationID? {
        guard let rawValue = options?[LavaSecAppGroup.latencyOperationIDOptionKey] as? String,
              !rawValue.isEmpty
        else {
            return nil
        }

        return LatencyOperationID(rawValue: rawValue)
    }

    #if DEBUG || LAVA_QA_TOOLS
    private static func makeLatencyTrace(operationID: LatencyOperationID?, operationKind: String) -> LatencyTrace {
        LatencyTrace(
            operationID: operationID ?? .make(),
            sink: LatencyDebugLogEventSink(operationKind: operationKind) { event, details in
                LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
            }
        )
    }
    #endif

    // MARK: - Packet read loop & DNS request handling

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else {
                return
            }

            for (packet, protocolNumber) in zip(packets, protocols) {
                handle(packet: packet, protocolNumber: protocolNumber)
            }

            readPackets()
        }
    }

    private let dnsQueryDispatcher = DNSQueryDispatcher()

    private func handle(packet: Data, protocolNumber: NSNumber) {
        guard let request = IPv4UDPDNSPacket(packet) else {
            return
        }

        handleDNSRequest(
            request,
            protocolNumber: protocolNumber.intValue,
            allowsTransientBootstrapDeferral: true,
            expectedLifecycleGeneration: nil
        )
    }

    private func handleDNSRequest(
        _ request: IPv4UDPDNSPacket,
        protocolNumber: Int,
        allowsTransientBootstrapDeferral: Bool,
        expectedLifecycleGeneration: UInt64?
    ) {
        if let expectedLifecycleGeneration,
           !isCurrentTunnelLifecycle(expectedLifecycleGeneration) {
            let pending = PendingDNSResponse(
                request: request,
                protocolNumber: protocolNumber,
                maximumAnswerTTL: nil,
                temporaryPauseNormalizedDomain: nil
            )
            writeServerFailures(for: [pending], reason: "transient-bootstrap-dns-wait-stale-lifecycle")
            return
        }

        guard let question = try? DNSMessage.parseQuestion(from: request.dnsPayload) else {
            writeParseFailureResponse(for: request, protocolNumber: protocolNumber)
            return
        }

        let resolverConfiguration = currentResolverRuntimeConfiguration()
        let protocolNumberObject = NSNumber(value: protocolNumber)
        // Captured inside the filterDecision closure (non-escaping, called synchronously by
        // the dispatcher) so the fail-closed reason is read under the SAME snapshotQueue
        // pass as the decision — a deferred read could describe a different resident
        // snapshot than the one that actually served the query.
        var failClosedReasonAtDecision: String?
        // Precedence (bootstrap > pause > filter) lives in the pure, tested
        // DNSQueryDispatcher; the closures stay lazy so each provider-state read
        // happens only when its step is reached (preserving the per-query cost).
        let decision = dnsQueryDispatcher.decide(
            bootstrapResponse: {
                dohBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration
                ) ?? doqBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration
                ) ?? dotBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration
                )
            },
            isProtectionPaused: {
                isTemporaryProtectionPauseActive(synchronizesDefaults: false)
            },
            filterDecision: {
                let (decision, failClosedReason) = filterDecisionCapturingFailClosedReason(
                    forNormalizedDomain: question.normalizedDomain
                )
                failClosedReasonAtDecision = failClosedReason
                return decision
            }
        )

        switch decision {
        case .bootstrap(let bootstrapResponse):
            resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)
            writeDNSResponse(bootstrapResponse, for: request, protocolNumber: protocolNumber)

        case .pausedForward:
            let maximumAnswerTTL = temporaryPauseMaximumAnswerTTL(forNormalizedDomain: question.normalizedDomain)
            recordDiagnostic(domain: question.domain, decision: .pausedAllow)
            recordFirstDNSDecisionIfNeeded("pause-allow")
            forward(
                request,
                protocolNumber: protocolNumberObject,
                resolverConfiguration: resolverConfiguration,
                maximumAnswerTTL: maximumAnswerTTL,
                temporaryPauseNormalizedDomain: question.normalizedDomain
            )

        case .filtered(let filterDecision):
            if enqueueTransientBootstrapDNSRequestIfNeeded(
                request: request,
                protocolNumber: protocolNumber,
                filterDecision: filterDecision,
                failClosedReason: failClosedReasonAtDecision,
                allowsTransientBootstrapDeferral: allowsTransientBootstrapDeferral
            ) {
                return
            }

            recordDiagnostic(
                domain: question.domain,
                decision: filterDecision,
                failClosedReason: failClosedReasonAtDecision
            )
            recordFirstDNSDecisionIfNeeded(filterDecision.action == .block ? "block" : "allow")
            guard filterDecision.action == .block else {
                forward(request, protocolNumber: protocolNumberObject, resolverConfiguration: resolverConfiguration)
                return
            }

            guard let response = try? DNSMessage.blockedResponse(
                for: request.dnsPayload,
                question: question,
                ttl: blockedTTL
            ) else {
                return
            }

            writeDNSResponse(response, for: request, protocolNumber: protocolNumber)
        }
    }

    // `resolverConfiguration` is taken from the caller (`handle`) rather than
    // recomputed here: `currentResolverRuntimeConfiguration()` performs several
    // blocking `dnsStateQueue.sync` reads, and `handle` already computed the SAME
    // value to drive the bootstrap/pause/filter decision. Reusing it keeps the
    // decision and the forward on one consistent runtime and removes a second
    // batch of queue hops from the per-query hot path. Staleness is still guarded
    // by `resetResolverRuntimeStateIfNeeded` below and the `isActiveResolverRuntime`
    // generation check before any response is written.
    //
    // Adoption timing: a resolver-config change (A→B) that commits AFTER `handle`
    // captured A at its entry — via the queued `refreshConfigurationIfNeeded` in
    // `recordDiagnostic`, or a concurrent snapshot reload — is adopted by the NEXT
    // query, not this one. This in-flight query is served under A, the runtime it
    // was classified on (previously `forward` re-read the config here and could
    // adopt B one query sooner). The lag is one query and self-correcting: the next
    // `handle` reads `appConfiguration == B` and its `forward` resets the runtime to
    // B. Because the reset is keyed on the captured identifier (not a live re-read),
    // `setAppConfiguration` alone never advances `activeResolverRuntimeIdentifier`,
    // so reset(A) hits the identity guard and no-ops rather than flipping a runtime
    // that is still A. The authoritative apply path
    // (`refreshDNSRuntimeAfterSnapshotOrConfigurationChange`, invoked from a snapshot
    // reload) is unaffected — it resets the runtime to the new identifier directly.
    // MARK: - Upstream forwarding & resolution pipeline

    private func forward(
        _ request: IPv4UDPDNSPacket,
        protocolNumber: NSNumber,
        resolverConfiguration: ResolverRuntimeConfiguration,
        maximumAnswerTTL: UInt32? = nil,
        temporaryPauseNormalizedDomain: String? = nil
    ) {
        resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)
        // The encrypted-fallback rejection trigger (`treatsResolverRejectionAsFallbackTrigger`)
        // derives from `currentDeviceResolverWedged()`, which is deliberately NOT part of
        // `cacheIdentifier` and does not advance the resolver-runtime generation — so a wedge flip
        // between `handle`'s capture of this plan and the resolution below is invisible to BOTH the
        // reset guard above and the `isActiveResolverRuntime` generation check. Re-read just that
        // volatile bit and recompute the trigger onto the captured plan, so a query straddling a
        // Device-DNS wedge onset is carried by the encrypted fallback instead of returning the
        // wedged resolver's SERVFAIL/REFUSED authoritatively (the exact transition the fallback
        // exists to cover). Gated on `shouldFallbackToEncrypted` — a captured field, no queue hop —
        // so encrypted-primary resolvers (no encrypted fallback) skip the read and keep the full
        // per-query savings; everything folded into `cacheIdentifier` is still reused from capture.
        let resolverConfiguration = resolverConfiguration.shouldFallbackToEncrypted
            ? resolverConfiguration.recomputingResolverRejectionFallbackTrigger(
                deviceResolverWedged: currentDeviceResolverWedged()
            )
            : resolverConfiguration
        let resolverGeneration = currentResolverRuntimeGeneration()
        let dnsPayload = request.dnsPayload
        let protocolValue = protocolNumber.intValue

        guard let cacheKey = DNSCacheKey(resolverIdentifier: resolverConfiguration.cacheIdentifier, dnsPayload: dnsPayload) else {
            runBoundedResolverWork { [weak self] finish in
                guard let self else {
                    finish()
                    return
                }

                self.resolveUpstream(dnsPayload, resolverConfiguration: resolverConfiguration) { [weak self] result in
                    defer {
                        finish()
                    }

                    let response = result.response ?? DNSResponseFactory.serverFailure(for: dnsPayload)

                    guard let response else {
                        return
                    }

                    let responseToWrite = self?.responseByApplyingMaximumAnswerTTL(
                        response,
                        maximumAnswerTTL: maximumAnswerTTL
                    ) ?? DNSResponseFactory.serverFailure(for: dnsPayload)

                    self?.dnsStateQueue.async { [weak self] in
                        guard let self,
                              let responseToWrite,
                              self.isActiveResolverRuntime(
                                identifier: resolverConfiguration.cacheIdentifier,
                                generation: resolverGeneration
                              )
                        else {
                            return
                        }

                        self.writeDNSResponse(responseToWrite, for: request, protocolNumber: protocolValue)
                    }
                }
            }

            return
        }

        let pending = PendingDNSResponse(
            request: request,
            protocolNumber: protocolValue,
            maximumAnswerTTL: maximumAnswerTTL,
            temporaryPauseNormalizedDomain: temporaryPauseNormalizedDomain
        )

        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.isActiveResolverRuntime(
                identifier: resolverConfiguration.cacheIdentifier,
                generation: resolverGeneration
            ) else {
                guard let response = DNSResponseFactory.serverFailure(for: dnsPayload) else {
                    return
                }

                self.writeDNSResponse(response, for: request, protocolNumber: protocolValue)
                return
            }

            let now = Date()
            if let cachedResponse = self.dnsResponseCache.cachedResponse(for: cacheKey, query: dnsPayload, now: now) {
                self.recordCacheHit()
                // Keep cache hits on the same write-path normalizer as upstream responses:
                // it applies the optional pause TTL cap and fails closed if a malformed cached
                // packet ever slips past the store-time validation.
                guard let responseToWrite = self.responseByApplyingMaximumAnswerTTL(
                    cachedResponse,
                    maximumAnswerTTL: maximumAnswerTTL
                ) ?? DNSResponseFactory.serverFailure(for: dnsPayload) else {
                    return
                }
                self.writeDNSResponse(responseToWrite, for: request, protocolNumber: protocolValue)
                return
            }

            self.recordCacheMiss()

            guard self.inFlightQueryCoalescer.enqueue(pending, for: cacheKey) == .startedResolution else {
                self.recordCoalescedQuery()
                return
            }

            self.dispatchForwardResolution(
                cacheKey: cacheKey,
                query: dnsPayload,
                resolverConfiguration: resolverConfiguration,
                resolverGeneration: resolverGeneration,
                maximumAnswerTTL: maximumAnswerTTL
            )
        }
    }

    private func dispatchForwardResolution(
        cacheKey: DNSCacheKey,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        resolverGeneration: Int,
        maximumAnswerTTL: UInt32?
    ) {
        runBoundedResolverWork { [weak self] finish in
            guard let self else {
                finish()
                return
            }

            let startedAt = Date()
            self.resolveUpstream(query, resolverConfiguration: resolverConfiguration) { [weak self] result in
                defer {
                    finish()
                }
                let result = result.recordingDuration(since: startedAt)

                self?.dnsStateQueue.async { [weak self] in
                    self?.completeForward(
                        cacheKey: cacheKey,
                        query: query,
                        resolverIdentifier: resolverConfiguration.cacheIdentifier,
                        resolverGeneration: resolverGeneration,
                        maximumAnswerTTL: maximumAnswerTTL,
                        result: result
                    )
                }
            }
        }
    }

    private func runBoundedResolverWork(
        _ work: @escaping @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void
    ) {
        // CON-4: queue-confined admission instead of a blocking semaphore. The unit stored in
        // the FIFO is a start-closure that dispatches the real (potentially blocking) resolver
        // work onto the concurrent resolverQueue; over-bound submissions wait inert in the FIFO
        // and NO thread is parked. `finish()` releases the slot on the same admission queue and
        // starts the next pending unit, if any. ResolverWorkCompletion keeps the release
        // idempotent (single signal per work item), exactly as before.
        let start: @Sendable () -> Void = { [weak self] in
            // If the provider is gone the whole admission machinery (queue + FIFO) is being
            // torn down with it, so there is no slot left to release — just drop the unit.
            guard let self else {
                return
            }

            self.resolverQueue.async {
                let completion = ResolverWorkCompletion { [weak self] in
                    self?.releaseResolverAdmissionSlot()
                }

                work {
                    completion.complete()
                }
            }
        }

        // The FIFO+activeCount live on resolverConcurrencyAdmission, reached through self
        // (@unchecked Sendable) and confined to resolverAdmissionQueue — the same idiom as the
        // dnsStateQueue-confined inFlightQueryCoalescer. Admit under the bound and start
        // immediately, otherwise the unit waits inert in the FIFO.
        resolverAdmissionQueue.async { [weak self] in
            guard let self else {
                return
            }

            if let admitted = self.resolverConcurrencyAdmission.admit(start) {
                admitted()
            }
        }
    }

    /// CON-4: free one resolver-admission slot and start the next pending unit (if any) —
    /// confined to `resolverAdmissionQueue`, where the FIFO+activeCount live. Called once per
    /// completed work item via ResolverWorkCompletion, mirroring the old semaphore `signal()`.
    private func releaseResolverAdmissionSlot() {
        resolverAdmissionQueue.async { [weak self] in
            guard let self else {
                return
            }

            if let next = self.resolverConcurrencyAdmission.release() {
                next()
            }
        }
    }

    private func runResolverSmokeProbeWork(
        _ work: @escaping @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void
    ) {
        resolverSmokeProbeQueue.async {
            let completion = ResolverWorkCompletion {}
            work {
                completion.complete()
            }
        }
    }

    private func writeDNSResponse(_ dnsPayload: Data, for request: IPv4UDPDNSPacket, protocolNumber: Int) {
        guard let packet = IPv4UDPDNSPacket.response(to: request, dnsPayload: dnsPayload) else {
            return
        }

        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: protocolNumber)])
    }

    private func resolveUpstream(
        _ query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        purpose: ResolverQueryPurpose = .forwarding,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        resolverOrchestrator.resolveUpstream(
            query,
            plan: resolverConfiguration,
            usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection,
            completion: completion
        )
    }

    private func resolvePrimaryUpstream(
        _ query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        purpose: ResolverQueryPurpose = .forwarding,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        resolverOrchestrator.resolvePrimaryUpstream(
            query,
            plan: resolverConfiguration,
            usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection,
            completion: completion
        )
    }

    private lazy var resolverOrchestrator = ResolverOrchestrator(executors: makeResolverExecutors())

    // Wire-level executors for the core orchestrator: transports, the
    // synchronous plain/device resolvers, and the backoff gate. Per-endpoint
    // debug logging and idle-reset-on-failure live here so the orchestrator
    // stays policy-pure.
    // MARK: - Resolver runtime & transports (device / plain / DoH / DoT / DoQ)

    private func makeResolverExecutors() -> ResolverOrchestrator.Executors {
        let dohResolver = dohResolver
        let dotResolver = dotResolver
        let doqResolver = doqResolver
        #if DEBUG || LAVA_QA_TOOLS
        // One wire attempt per span. "Endpoint fallback" is the multi-attempt
        // subset (an attempt whose outcome != success followed by another), so
        // the per-attempt distribution and the failover cost both fall out of
        // aggregating resolver.endpointAttempt by name. The handshake sub-cost
        // is layered underneath via the transports' dns-<t>-connection-ready
        // debug events.
        let resolverLatencyOperationID = self.resolverLatencyOperationID
        let beginResolverSpan: @Sendable (String, [String: String]) -> LatencySpan = { name, details in
            Self.makeLatencyTrace(operationID: resolverLatencyOperationID, operationKind: "resolver")
                .beginSpan(name, details: details)
        }
        let endAttemptSpan: @Sendable (LatencySpan, DNSTransportResponse) -> Void = { span, upstreamResponse in
            span.end(details: [
                "outcome": upstreamResponse.outcome.rawValue,
                "succeeded": "\(upstreamResponse.response != nil)"
            ])
        }
        #endif
        return ResolverOrchestrator.Executors(
            isEndpointBackedOff: { [weak self] address in
                self?.isResolverBackedOff(address) ?? false
            },
            resolveDoH: { query, endpoint, completion in
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoH"])
                #endif
                dohResolver.resolve(query, endpoint: endpoint.url) { upstreamResponse in
                    if upstreamResponse.response == nil {
                        dohResolver.resetSessionWhenIdle()
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif
                    completion(upstreamResponse)
                }
            },
            resolveDoT: { query, endpoint, usesIsolatedConnection, completion in
                #if DEBUG || LAVA_QA_TOOLS
                // Per-query "begin" trace is verbose Debug/QA instrumentation; it is
                // kept off the Release DNS hot path (no diagnostic value without the
                // matching result, which Release logs only on failure below).
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-dot-query-begin", details: [
                    "endpoint": endpoint.displayAddress,
                    "bootstrapCount": "\(endpoint.allBootstrapServers.count)"
                ])
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoT"])
                #endif

                let finish: @Sendable (DNSTransportResponse) -> Void = { upstreamResponse in
                    if upstreamResponse.response == nil, !usesIsolatedConnection {
                        dotResolver.resetConnectionsWhenIdle()
                    }

                    let succeeded = upstreamResponse.response != nil
                    #if DEBUG || LAVA_QA_TOOLS
                    let shouldLogResult = true
                    #else
                    // Release: keep per-query logging off the DNS success hot path
                    // (appendLine open/write/close per query adds resolution
                    // latency). Failures are rare and are exactly the signal needed
                    // to diagnose a Wi-Fi/cellular handoff, so log only those.
                    let shouldLogResult = !succeeded
                    #endif
                    if shouldLogResult {
                        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-dot-query-result", details: [
                            "endpoint": endpoint.displayAddress,
                            "outcome": upstreamResponse.outcome.rawValue,
                            "succeeded": "\(succeeded)"
                        ])
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif

                    completion(upstreamResponse)
                }

                if usesIsolatedConnection {
                    dotResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)
                } else {
                    dotResolver.resolve(query, endpoint: endpoint, completion: finish)
                }
            },
            resolveDoQ: { query, endpoint, usesIsolatedConnection, completion in
                #if DEBUG || LAVA_QA_TOOLS
                // Per-query "begin" trace is verbose Debug/QA instrumentation; kept
                // off the Release DNS hot path (see DoT path above).
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-query-begin", details: [
                    "endpoint": endpoint.displayAddress
                ])
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoQ"])
                #endif

                let finish: @Sendable (DNSTransportResponse) -> Void = { upstreamResponse in
                    if upstreamResponse.response == nil, !usesIsolatedConnection {
                        doqResolver.resetConnectionsWhenIdle()
                    }

                    let succeeded = upstreamResponse.response != nil
                    #if DEBUG || LAVA_QA_TOOLS
                    let shouldLogResult = true
                    #else
                    // Release: only log failures to keep per-query I/O off the DNS
                    // success hot path (see DoT path above).
                    let shouldLogResult = !succeeded
                    #endif
                    if shouldLogResult {
                        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-query-result", details: [
                            "endpoint": endpoint.displayAddress,
                            "outcome": upstreamResponse.outcome.rawValue,
                            "succeeded": "\(succeeded)"
                        ])
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif

                    completion(upstreamResponse)
                }

                if usesIsolatedConnection {
                    doqResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)
                } else {
                    doqResolver.resolve(query, endpoint: endpoint, completion: finish)
                }
            },
            resolvePlain: { [weak self] query, addresses, transport in
                guard let self else {
                    return DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [],
                        transport: transport,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false
                    )
                }

                // Plain DNS iterates addresses with UDP-then-TCP and backoff
                // internally, so one span covers the whole plain resolution
                // (the dominant DNS phase for users on a plain-IP resolver).
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "plain"])
                #endif
                let result = self.resolvePlainDNS(query, resolverAddresses: addresses, transport: transport)
                #if DEBUG || LAVA_QA_TOOLS
                attemptSpan.end(details: [
                    "outcome": result.failureSummary ?? "success",
                    "succeeded": "\(result.response != nil)",
                    "usedTCP": "\(result.tcpFallbackAttempted)"
                ])
                #endif
                return result
            },
            resolveDevice: { [weak self] query, addresses in
                guard let self else {
                    return DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [],
                        transport: .deviceDNS,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false,
                        deviceDNSUnavailable: true
                    )
                }

                #if DEBUG || LAVA_QA_TOOLS
                let fallbackSpan = beginResolverSpan("resolver.deviceFallback", [:])
                #endif
                let result = self.resolveDeviceDNS(query, resolverAddresses: addresses)
                #if DEBUG || LAVA_QA_TOOLS
                fallbackSpan.end(details: ["succeeded": "\(result.response != nil)"])
                #endif
                return result
            }
        )
    }

    private func resolveDeviceDNS(_ query: Data, resolverAddresses: [String]) -> DNSResolutionResult {
        guard !resolverAddresses.isEmpty else {
            return DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(
                        address: DNSResolverPreset.device.id,
                        outcome: .deviceDNSUnavailable,
                        transport: .deviceDNS
                    )
                ],
                transport: .deviceDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false,
                deviceDNSUnavailable: true
            )
        }

        return resolvePlainDNS(query, resolverAddresses: resolverAddresses, transport: .deviceDNS)
    }

    private func resolvePlainDNS(
        _ query: Data,
        resolverAddresses: [String],
        transport: DNSResolverTransport = .plainDNS
    ) -> DNSResolutionResult {
        var attempts: [ResolverAttempt] = []
        var sawUDPTruncation = false
        var attemptedTCPFallback = false

        let addressesForAttempt = orderedResolverAddressesForAttempt(resolverAddresses)
        if addressesForAttempt.isEmpty, !resolverAddresses.isEmpty {
            return DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: resolverAddresses.map {
                    ResolverAttempt(address: $0, outcome: .backedOff, transport: transport)
                },
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            )
        }

        for address in addressesForAttempt {
            guard let endpoint = ResolverEndpoint(address: address) else {
                attempts.append(ResolverAttempt(address: address, outcome: .invalidAddress, transport: transport))
                continue
            }

            let udpResult = resolveUDP(query, endpoint: endpoint)
            attempts.append(ResolverAttempt(address: address, outcome: udpResult.outcome, transport: transport))

            guard let udpResponse = udpResult.response else {
                guard shouldAttemptTCPFallback(afterUDPOutcome: udpResult.outcome) else {
                    continue
                }

                attemptedTCPFallback = true
                let tcpResult = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: Self.tcpDNSTimeoutSeconds)
                attempts.append(
                    ResolverAttempt(
                        address: address,
                        outcome: tcpResult.outcome,
                        transport: transport,
                        usedTCP: true
                    )
                )

                if let tcpResponse = tcpResult.response {
                    return DNSResolutionResult(
                        response: tcpResponse,
                        successfulResolverAddress: address,
                        attempts: attempts,
                        transport: transport,
                        udpTruncated: sawUDPTruncation,
                        tcpFallbackAttempted: attemptedTCPFallback,
                        tcpFallbackSucceeded: true
                    )
                }

                continue
            }

            if DNSMessageTraits.isTruncated(udpResponse) {
                sawUDPTruncation = true
                attemptedTCPFallback = true
                let tcpResult = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: Self.tcpDNSTimeoutSeconds)
                attempts.append(
                    ResolverAttempt(
                        address: address,
                        outcome: tcpResult.outcome,
                        transport: transport,
                        usedTCP: true
                    )
                )

                if let tcpResponse = tcpResult.response {
                    return DNSResolutionResult(
                        response: tcpResponse,
                        successfulResolverAddress: address,
                        attempts: attempts,
                        transport: transport,
                        udpTruncated: true,
                        tcpFallbackAttempted: attemptedTCPFallback,
                        tcpFallbackSucceeded: true
                    )
                }

                continue
            }

            return DNSResolutionResult(
                response: udpResponse,
                successfulResolverAddress: address,
                attempts: attempts,
                transport: transport,
                udpTruncated: sawUDPTruncation,
                tcpFallbackAttempted: attemptedTCPFallback,
                tcpFallbackSucceeded: false
            )
        }

        return DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: attempts,
            transport: transport,
            udpTruncated: sawUDPTruncation,
            tcpFallbackAttempted: attemptedTCPFallback,
            tcpFallbackSucceeded: false
        )
    }

    private func shouldAttemptTCPFallback(afterUDPOutcome outcome: ResolverAttemptOutcome) -> Bool {
        switch outcome {
        case .timeout:
            return true
        case .sendFailed:
            return false
        case .success,
             .httpStatusFailure,
             .backedOff,
             .receiveFailed,
             .invalidAddress,
             .unsupported,
             .socketUnavailable,
             .mismatchedResponse,
             .deviceDNSUnavailable:
            return false
        }
    }

    private lazy var resolverBootstrapService = ResolverBootstrapService(
        resolveAddresses: { [weak self] hostname in
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
            let bootstrap = self.resolveDoQBootstrapAddresses(for: hostname, resolverAddresses: resolverAddresses)
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

    private lazy var resolverProbeCoalescer = NetworkSettleCoalescer(
        settleInterval: resolverProbeSettleInterval,
        scheduler: DispatchSettleWorkScheduler(queue: dnsStateQueue),
        work: { [weak self] in
            self?.performCoalescedNetworkSettleProbe()
        }
    )

    /// Runs the deferred proactive resolver rebuild (DoQ bootstrap pre-warm + DNS
    /// smoke probe) once the network path has settled. The connection teardown for
    /// each change already happened immediately in `handleNetworkPathUpdate`; only
    /// this proactive work is coalesced so a flap burst re-handshakes once, not per
    /// flap.
    private func performCoalescedNetworkSettleProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.performCoalescedNetworkSettleProbe()
            }
            return
        }

        guard health.networkPathIsSatisfied else {
            return
        }

        // Best-effort device-DNS re-capture once the new network has settled.
        //
        // KNOWN-INEFFECTIVE WHILE MASKED (field evidence, 1758 device log): on the
        // cellular networks observed, EVERY in-tunnel capture returns empty — iOS
        // surfaces only the tunnel's own 10.255.0.1 (which we filter out) while the
        // tunnel is active. Across that session all 98 `network-settled` and 98
        // `wake` captures were count:0; the only non-empty captures (count:2) were
        // the two cold `startTunnel`s. So preserveOnEmptyCapture keeps the PREVIOUS
        // network's resolvers, and on a resolver-CHANGING handoff those are
        // unreachable (timeout) → a wedge that only a tunnel restart (self-reconnect,
        // which re-captures at cold start) actually fixes. Do NOT rely on this
        // re-capture for handoff recovery; it is kept because it is harmless and may
        // still help on networks/iOS versions that don't mask. If they changed,
        // reset the runtime so the fresh addresses take effect (mirrors wake()).
        let previousDeviceDNSResolverAddresses = deviceDNSResolverAddresses
        refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "network-settled")
        if deviceDNSResolverAddresses != previousDeviceDNSResolverAddresses {
            let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
            let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
                identifier: resolverIdentifier,
                reason: "device-dns-recaptured-on-settle",
                force: true
            )
            writeServerFailures(for: pendingResponses, reason: "device-dns-recaptured-on-settle")
        }

        prewarmResolverBootstrapIfNeeded()
        scheduleResolverSmokeProbeIfNeeded(reason: "network-settled")
    }

    // MARK: - Encrypted-resolver bootstrap (endpoint hostname resolution)

    private func dohEndpointResolvingBootstrapIfNeeded(_ endpoint: DNSOverHTTPSEndpoint) -> DNSOverHTTPSEndpoint {
        // A built-in DoH endpoint ships with bootstrap IPs; a user-typed custom
        // `https://host` resolver does not. Resolve the missing bootstrap from the
        // hostname cache (warmed while Device DNS was reachable) so the DoH client
        // can connect even when the device resolver is wedged — mirroring the DoQ
        // path. Literal-IP hosts and already-bootstrapped endpoints pass through.
        guard endpoint.allBootstrapServers.isEmpty,
              let host = endpoint.url.host,
              ResolverEndpoint(address: host) == nil
        else {
            return endpoint
        }

        guard let cached = resolverBootstrapService.cachedAddresses(forHostname: host) else {
            // Never block the packet path on a bootstrap lookup: warm the cache
            // asynchronously (pre-warms at tunnel start, resolver switches, and
            // network changes make this miss rare).
            resolverBootstrapService.prewarm(hostname: host)
            return endpoint
        }

        return DNSOverHTTPSEndpoint(
            url: endpoint.url,
            bootstrapIPv4Servers: cached.ipv4,
            bootstrapIPv6Servers: cached.ipv6
        )
    }

    private func dotEndpointResolvingBootstrapIfNeeded(_ endpoint: DNSOverTLSEndpoint) -> DNSOverTLSEndpoint {
        // As with DoH/DoQ: a built-in DoT endpoint ships bootstrap IPs, a user-typed
        // custom `tls://host` resolver does not. Fill the missing IPs from the warmed
        // hostname cache so the DoT connection doesn't have to resolve its own hostname
        // through a wedged Device DNS. Literal-IP hosts and already-bootstrapped
        // endpoints pass through.
        guard endpoint.allBootstrapServers.isEmpty,
              ResolverEndpoint(address: endpoint.hostname) == nil
        else {
            return endpoint
        }

        guard let cached = resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname) else {
            resolverBootstrapService.prewarm(hostname: endpoint.hostname)
            return endpoint
        }

        return DNSOverTLSEndpoint(
            hostname: endpoint.hostname,
            port: endpoint.port,
            bootstrapIPv4Servers: cached.ipv4,
            bootstrapIPv6Servers: cached.ipv6
        )
    }

    private func doqEndpointResolvingBootstrapIfNeeded(_ endpoint: DNSOverQUICEndpoint) -> DNSOverQUICEndpoint {
        guard endpoint.allBootstrapServers.isEmpty,
              ResolverEndpoint(address: endpoint.hostname) == nil
        else {
            return endpoint
        }

        guard let cached = resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname) else {
            // Never block the packet path on a bootstrap lookup: warm the
            // cache asynchronously and let the stub resolver's retry find the
            // addresses (pre-warms at tunnel start, resolver switches, and
            // network changes make this miss rare).
            resolverBootstrapService.prewarm(hostname: endpoint.hostname)
            return endpoint
        }

        return DNSOverQUICEndpoint(
            hostname: endpoint.hostname,
            port: endpoint.port,
            bootstrapIPv4Servers: cached.ipv4,
            bootstrapIPv6Servers: cached.ipv6
        )
    }

    private func prewarmResolverBootstrapIfNeeded() {
        let resolverConfiguration = currentResolverRuntimeConfiguration()
        // Prewarm the primary's DoQ endpoints (when DoQ is the active transport) AND
        // any encrypted-fallback DoQ endpoints (a custom `doq://` fallback a wedged
        // Device-DNS primary keeps). The fallback host must be bootstrapped even
        // though the primary transport is Device DNS, mirroring the DoH fallback.
        var doqEndpoints = resolverConfiguration.encryptedFallbackDoQEndpoints
        if resolverConfiguration.transport == .dnsOverQUIC {
            doqEndpoints = resolverConfiguration.doqEndpoints + doqEndpoints
        }

        for endpoint in doqEndpoints
        where endpoint.allBootstrapServers.isEmpty && ResolverEndpoint(address: endpoint.hostname) == nil {
            resolverBootstrapService.prewarm(hostname: endpoint.hostname)
        }

        // Same for DoH: a user-typed custom `https://host` resolver (primary or the
        // encrypted fallback) ships no bootstrap IPs, so warm its hostname while the
        // device resolver is reachable. Built-in endpoints carry their own IPs and
        // are skipped (allBootstrapServers non-empty).
        var dohEndpoints = resolverConfiguration.encryptedFallbackEndpoints
        if resolverConfiguration.transport == .dnsOverHTTPS {
            dohEndpoints = resolverConfiguration.dohEndpoints + dohEndpoints
        }

        for endpoint in dohEndpoints where endpoint.allBootstrapServers.isEmpty {
            guard let host = endpoint.url.host, ResolverEndpoint(address: host) == nil else {
                continue
            }
            resolverBootstrapService.prewarm(hostname: host)
        }

        // And DoT: a custom `tls://host` resolver (primary or encrypted fallback)
        // connects by hostname when it has no bootstrap IPs, so warm its hostname too.
        var dotEndpoints = resolverConfiguration.encryptedFallbackDoTEndpoints
        if resolverConfiguration.transport == .dnsOverTLS {
            dotEndpoints = resolverConfiguration.dotEndpoints + dotEndpoints
        }

        for endpoint in dotEndpoints
        where endpoint.allBootstrapServers.isEmpty && ResolverEndpoint(address: endpoint.hostname) == nil {
            resolverBootstrapService.prewarm(hostname: endpoint.hostname)
        }
    }

    private func resolveDoQBootstrapAddresses(
        for hostname: String,
        resolverAddresses: [String]
    ) -> (ipv4: [String], ipv6: [String]) {
        let aQuery = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: hostname,
            recordType: DNSRecordType.a.rawValue
        )
        let aResult = resolvePlainDNS(aQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS)
        let ipv4 = DNSBootstrapAddressExtractor.addresses(from: aResult.response, matching: aQuery, recordType: .a)

        let aaaaQuery = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: hostname,
            recordType: DNSRecordType.aaaa.rawValue
        )
        let aaaaResult = resolvePlainDNS(aaaaQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS)
        let ipv6 = DNSBootstrapAddressExtractor.addresses(from: aaaaResult.response, matching: aaaaQuery, recordType: .aaaa)

        return (ipv4, ipv6)
    }

    private func resolveUDP(_ query: Data, endpoint: ResolverEndpoint) -> DNSUpstreamResponse {
        // A short-lived per-query socket (like TCPResolver) so the blocking recvfrom
        // runs on the concurrent resolverQueue instead of serializing every plain/
        // device UDP query through one queue — a single slow/unreachable resolver
        // otherwise head-of-line-blocks all plain/device DNS for up to the UDP
        // timeout. Per-query sockets also mean concurrent queries never share one FD,
        // removing the cross-talk the mismatched-response budget only partly absorbs.
        // The socket's deinit closes the descriptor when this returns.
        guard let socket = UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.udpDNSTimeoutSeconds) else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        return socket.resolve(query)
    }

    private func orderedResolverAddressesForAttempt(_ addresses: [String], now: Date = Date()) -> [String] {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.availableAddresses(from: addresses, now: now)
        }
    }

    private func isResolverBackedOff(_ address: String, now: Date = Date()) -> Bool {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.isBackedOff(address, now: now)
        }
    }

    private func completeForward(
        cacheKey: DNSCacheKey,
        query: Data,
        resolverIdentifier: String,
        resolverGeneration: Int,
        maximumAnswerTTL: UInt32?,
        result: DNSResolutionResult
    ) {
        guard isActiveResolverRuntime(identifier: resolverIdentifier, generation: resolverGeneration) else {
            return
        }

        let pendingResponses = inFlightQueryCoalescer.drain(cacheKey)
        recordUpstreamResult(result)

        let upstreamResponse = result.response ?? DNSResponseFactory.serverFailure(for: query)

        guard let upstreamResponse else {
            return
        }
        let responseToWrite = DNSWireMessage.hasWellFormedResourceRecords(upstreamResponse)
            ? upstreamResponse
            : DNSResponseFactory.serverFailure(for: query)
        guard let responseToWrite else {
            return
        }

        let cacheMaximumAnswerTTL = pendingResponses
            .compactMap(\.maximumAnswerTTL)
            .min()
            ?? maximumAnswerTTL
        let responseToCache = responseByApplyingMaximumAnswerTTL(
            responseToWrite,
            maximumAnswerTTL: cacheMaximumAnswerTTL
        )

        if let responseToCache {
            dnsResponseCache.store(responseToCache, for: cacheKey)
        }

        for pending in pendingResponses {
            guard let pendingResponse = responseForPendingForward(
                responseToWrite,
                pending: pending
            ) else {
                continue
            }
            let response = DNSWireMessage.replacingTransactionID(in: pendingResponse, from: pending.request.dnsPayload)
            writeDNSResponse(response, for: pending.request, protocolNumber: pending.protocolNumber)
        }
    }

    private func responseByApplyingMaximumAnswerTTL(
        _ response: Data,
        maximumAnswerTTL: UInt32?
    ) -> Data? {
        guard DNSWireMessage.hasWellFormedResourceRecords(response) else {
            return nil
        }
        guard let maximumAnswerTTL else {
            return response
        }

        return DNSWireMessage.cappingCacheableTTLs(in: response, to: maximumAnswerTTL)
    }

    private func responseForPendingForward(
        _ response: Data,
        pending: PendingDNSResponse
    ) -> Data? {
        if let normalizedDomain = pending.temporaryPauseNormalizedDomain,
           !isTemporaryProtectionPauseActive(synchronizesDefaults: false),
           protectionPolicyDecision(forNormalizedDomain: normalizedDomain).action == .block {
            return try? DNSMessage.blockedResponse(
                for: pending.request.dnsPayload,
                ttl: blockedTTL
            )
        }

        return responseByApplyingMaximumAnswerTTL(
            response,
            maximumAnswerTTL: pending.maximumAnswerTTL
        )
    }

    private func writeParseFailureResponse(for request: IPv4UDPDNSPacket, protocolNumber: Int) {
        guard let response = DNSResponseFactory.serverFailure(for: request.dnsPayload) else {
            return
        }

        writeDNSResponse(response, for: request, protocolNumber: protocolNumber)
    }

    private func currentResolverRuntimeGeneration() -> Int {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return resolverRuntimeGeneration
        }

        return dnsStateQueue.sync {
            resolverRuntimeGeneration
        }
    }

    private func isActiveResolverRuntime(identifier: String, generation: Int) -> Bool {
        activeResolverRuntimeIdentifier == identifier && resolverRuntimeGeneration == generation
    }


    private func currentResolverRuntimeConfiguration(
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true
    ) -> ResolverRuntimeConfiguration {
        let configuration = currentAppConfiguration()
        return DNSResolverRuntimePlan.make(
            configuration: configuration,
            deviceDNSAddresses: currentDeviceDNSResolverAddresses(),
            networkKind: currentNetworkKind(),
            deviceDNSFallbackModeActive: currentDeviceDNSFallbackModeActive(),
            ignoresDeviceDNSFallbackMode: ignoresDeviceDNSFallbackMode,
            allowsQueryFallback: allowsQueryFallback,
            deviceResolverWedged: currentDeviceResolverWedged()
        )
    }

    // "Broadly wedged" evidence for the encrypted fallback: the connectivity policy
    // has declared a needs-reconnect wedge (driven by the smoke probe on known-good
    // domains + consecutive upstream failures) and it hasn't recovered. This is NOT
    // reset by individual SERVFAIL/REFUSED forwarding replies, so a stale off-network
    // resolver that refuses everything still trips it via the smoke probe, while a
    // healthy resolver answering one blocked domain with REFUSED does not.
    private func currentDeviceResolverWedged() -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return reconnectNeededSince != nil
        }

        return dnsStateQueue.sync {
            reconnectNeededSince != nil
        }
    }

    private func orderedResolverAddressesForCurrentNetwork(_ addresses: [String]) -> [String] {
        DNSResolverRuntimePlan.orderedResolverAddresses(addresses, networkKind: currentNetworkKind())
    }

    /// `DomainName.normalize` memoized for a resolver endpoint hostname — the bootstrap checks
    /// call this per candidate endpoint on every DNS packet, and the hostnames are stable for the
    /// resolver runtime. Returns exactly what `try? DomainName.normalize(hostname)` would (the
    /// cached success, or nil for a hostname that fails to normalize). Resolver hostnames that
    /// fail normalization are not cached (recomputed on each call, matching the prior `try?`
    /// behaviour) — in practice resolver hostnames are always valid, so this path is not hit.
    private func normalizedEndpointHostname(_ hostname: String) -> String? {
        endpointHostnameNormalizationCacheLock.lock()
        if let cached = endpointHostnameNormalizationCache[hostname] {
            endpointHostnameNormalizationCacheLock.unlock()
            return cached
        }
        endpointHostnameNormalizationCacheLock.unlock()

        guard let normalized = try? DomainName.normalize(hostname) else {
            return nil
        }

        endpointHostnameNormalizationCacheLock.lock()
        if endpointHostnameNormalizationCache.count >= Self.endpointHostnameNormalizationCacheLimit {
            endpointHostnameNormalizationCache.removeAll(keepingCapacity: true)
        }
        endpointHostnameNormalizationCache[hostname] = normalized
        endpointHostnameNormalizationCacheLock.unlock()
        return normalized
    }

    private func clearEndpointHostnameNormalizationCache() {
        endpointHostnameNormalizationCacheLock.lock()
        endpointHostnameNormalizationCache.removeAll(keepingCapacity: true)
        endpointHostnameNormalizationCacheLock.unlock()
    }

    private func dohBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> Data? {
        // Hostnames that must be answered from bundled bootstrap IPs rather than
        // forwarded (forwarding would recurse through the very resolver we're trying
        // to reach):
        //   - the active DoH primary's endpoints, and
        //   - the encrypted fallback endpoints (Mullvad), which a Device-DNS primary
        //     keeps for the wedge safety net. Without bootstrapping the fallback host,
        //     its own `dns.mullvad.net` lookup would be forwarded to the (possibly
        //     wedged) Device DNS, so the safety net couldn't recover a cold device.
        var candidateEndpoints = resolverConfiguration.encryptedFallbackEndpoints
        if resolverConfiguration.transport == .dnsOverHTTPS {
            candidateEndpoints = resolverConfiguration.dohEndpoints + candidateEndpoints
        }

        // `question.normalizedDomain` is `DomainName.normalize(question.domain)`, already
        // computed once in `DNSMessage.parseQuestion`. Reuse it instead of re-normalizing
        // on every query: the bootstrap closure runs first on every DNS packet, and for a
        // non-resolver hostname (the common case) all three transports' checks run, so this
        // previously re-normalized the question domain up to 3× per query.
        let normalizedQuestionDomain = question.normalizedDomain
        guard !candidateEndpoints.isEmpty,
              let endpoint = candidateEndpoints.first(where: { endpoint in
                  guard let endpointHost = endpoint.url.host,
                        let normalizedEndpointHost = normalizedEndpointHostname(endpointHost)
                  else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        let bootstrappedEndpoint = dohEndpointResolvingBootstrapIfNeeded(endpoint)
        guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {
            // A custom DoH endpoint with no bootstrap IPs yet (cache not warmed).
            // Answering from empty arrays would hand the client an empty record set
            // and guarantee the connection fails; forwarding the hostname normally at
            // least resolves while Device DNS is healthy, so don't intercept here.
            return nil
        }

        // Bootstrap answers for the selected DoH hostname bypass filtering and diagnostics to avoid resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)
    }

    private func doqBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> Data? {
        // Candidate DoQ hostnames to answer from bundled bootstrap IPs rather than
        // forward (forwarding would recurse through the very resolver we're reaching):
        //   - the active DoQ primary's endpoints, and
        //   - the encrypted fallback's DoQ endpoints (a custom `doq://` fallback a
        //     Device-DNS primary keeps for the wedge safety net). Without bootstrapping
        //     the fallback host, its lookup would be forwarded to the (possibly wedged)
        //     Device DNS, so the safety net couldn't recover a cold device — the same
        //     reasoning as the DoH fallback in `dohBootstrapResponse`.
        var candidateEndpoints = resolverConfiguration.encryptedFallbackDoQEndpoints
        if resolverConfiguration.transport == .dnsOverQUIC {
            candidateEndpoints = resolverConfiguration.doqEndpoints + candidateEndpoints
        }

        // Reuse question.normalizedDomain instead of re-normalizing per query (see dohBootstrapResponse).
        let normalizedQuestionDomain = question.normalizedDomain
        guard !candidateEndpoints.isEmpty,
              let endpoint = candidateEndpoints.first(where: { endpoint in
                  guard let normalizedEndpointHost = normalizedEndpointHostname(endpoint.hostname) else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        let bootstrappedEndpoint = doqEndpointResolvingBootstrapIfNeeded(endpoint)
        guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {
            return nil
        }

        // Bootstrap answers for the selected DoQ hostname keep NWConnection hostname-based for SNI/cert validation while avoiding resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)
    }

    private func dotBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> Data? {
        // Candidate DoT hostnames to answer from bundled/cached bootstrap IPs rather
        // than forward (forwarding would recurse through the very resolver we're
        // reaching). `DoTTransport` connects by hostname when an endpoint has no
        // bootstrap IPs, so without this a custom `tls://` fallback (or primary) would
        // resolve its own hostname through the (possibly wedged) Device DNS — the same
        // reasoning as the DoH/DoQ bootstraps.
        var candidateEndpoints = resolverConfiguration.encryptedFallbackDoTEndpoints
        if resolverConfiguration.transport == .dnsOverTLS {
            candidateEndpoints = resolverConfiguration.dotEndpoints + candidateEndpoints
        }

        // Reuse question.normalizedDomain instead of re-normalizing per query (see dohBootstrapResponse).
        let normalizedQuestionDomain = question.normalizedDomain
        guard !candidateEndpoints.isEmpty,
              let endpoint = candidateEndpoints.first(where: { endpoint in
                  guard let normalizedEndpointHost = normalizedEndpointHostname(endpoint.hostname) else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        let bootstrappedEndpoint = dotEndpointResolvingBootstrapIfNeeded(endpoint)
        guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {
            return nil
        }

        // Bootstrap answers for the selected DoT hostname keep NWConnection hostname-based for SNI/cert validation while avoiding resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)
    }

    /// DESIGN / ENERGY TRADE-OFF (NRG — deferred, no behavior change here):
    /// This repeating timer is the ONE periodic that issues a real upstream DNS wire
    /// query on its cadence, so it is the most expensive steady-state probe: every
    /// 300 s it can wake the radio. It CANNOT be made purely event-driven: its entire
    /// purpose is to catch a resolver that went SILENTLY dead while there is no
    /// organic traffic to prove otherwise — an idle tunnel has no other signal. The
    /// cadence (300 s) is deliberately the "honesty budget" and stays fixed; lowering
    /// it widens blind-spot windows and raising it costs more energy for no gain.
    ///
    /// The energy cost is already mitigated by NRG-3a: `scheduleResolverSmokeProbe-
    /// IfNeeded` SKIPS the wire query when acceptance-checked primary evidence
    /// (a probe success or an organic primary answer passing the SAME acceptance
    /// check) is younger than one interval — so under live browsing the timer still
    /// fires (a CPU wake) but the radio wake is suppressed. The residual cost is one
    /// CPU wake + skip-predicate evaluation per 300 s on an idle-but-healthy tunnel;
    /// the 30 s leeway lets the kernel coalesce it. A future change must keep the
    /// cadence as the honesty budget and must NOT let skip evidence come from a
    /// merely-resolved reply (a hijacking resolver's REFUSED/SERVFAIL stamps those —
    /// the LAV-87 suppression regression), nor survive a resolver-runtime reset.
    ///
    /// (Honesty note, review 2026-07-05: two directions on the residual. SMALLER —
    /// the 30 s leeway already coalesces much of the idle radio wake into other
    /// activity, so the true marginal cost is below the naive one-wake-per-300 s.
    /// LARGER — a periodic-probe SUCCESS deliberately does NOT refresh the
    /// accepted-primary evidence stamp (only organic traffic does), so a
    /// steadily-idle-but-healthy tunnel keeps probing at full cadence and each probe
    /// pays a COLD handshake, not a warm round-trip; an always-cellular-all-day-idle
    /// phone is the only cohort where this is non-trivial. The one tweak that trims
    /// idle radio energy WITHOUT widening the dead-resolver window is widening this
    /// timer's leeway — measure the coalesced idle cost on-device before changing
    /// even that. NRG-3a already captured the main (live-traffic) win.)
    // MARK: - Periodic resolver smoke probe

    private func startPeriodicResolverSmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.startPeriodicResolverSmokeProbe()
            }
            return
        }

        resolverSmokeProbeTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: dnsStateQueue)
        // 10% leeway: nothing gates on tick phase, so let the kernel coalesce this wake
        // with other system activity instead of forcing a strict lone wake every 300 s.
        // The cadence itself is the honesty budget and stays untouched.
        timer.schedule(
            deadline: .now() + Self.resolverSmokeProbeInterval,
            repeating: Self.resolverSmokeProbeInterval,
            leeway: .seconds(30)
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleResolverSmokeProbeIfNeeded(reason: "periodic-health-check")
        }
        resolverSmokeProbeTimer = timer
        timer.resume()
    }

    private func stopPeriodicResolverSmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.stopPeriodicResolverSmokeProbe()
            }
            return
        }

        resolverSmokeProbeTimer?.cancel()
        resolverSmokeProbeTimer = nil
    }

    // MARK: - Focus filter switch config poll (LAV-100 Phase 4 P4d)

    /// Start the periodic poll that adopts a Focus-committed filter switch made by the App Intents
    /// extension while Lava is closed. The extension commits config + library + the artifact-pointer flip
    /// (that part works headless); this is how the always-on tunnel NOTICES — it reads the on-disk
    /// configuration generation each tick and reloads through the EXISTING `requestSnapshotReload` entry
    /// when it advances past the generation the tunnel last loaded. Reliable where a Darwin observer is not
    /// (the tunnel run loop does not service Darwin notifications when idle). Does NOT touch DNS recovery.
    ///
    /// DESIGN / ENERGY TRADE-OFF (NRG — deferred, no behavior change here):
    /// This is a constant ~60 s heartbeat for the whole life of the tunnel — a CPU
    /// wake + on-disk generation read every tick even when nothing changed (no radio
    /// wake unless the generation advanced and a reload runs). Polling is used over
    /// an event-driven signal for a concrete reliability reason, not by default: a
    /// Darwin-notification observer was proven UNRELIABLE in this NE extension
    /// (0 callbacks / 14 device probes), and a `DispatchSource` vnode/.write monitor
    /// on the generation file carries the same run-loop-when-idle risk that sank the
    /// Darwin observer. So the poll is the hard invariant; the 10 s leeway lets the
    /// kernel coalesce the wake with other system activity, and the reload itself is
    /// skipped (not re-requested) when the generation has not advanced or a reload is
    /// already in flight. A future event-driven replacement must FIRST be proven to
    /// fire reliably in the idle NE process at volume (re-running the device-probe
    /// harness) before this timer can be retired — otherwise a closed-app Focus switch
    /// silently stops being adopted.
    ///
    /// (Precision + scope, review 2026-07-05: a `DispatchSource` vnode source is
    /// kqueue-based, so it is not literally the Darwin "run loop not serviced when
    /// idle" failure — the stronger reason it is unattractive is that the config file
    /// is written atomically (temp+rename), so the watched inode is unlinked on every
    /// write and the source can MISS the replace. It also could not retire this timer
    /// anyway: the tick does DOUBLE DUTY — `reloadSnapshotIfConfigurationGeneration-
    /// Advanced` runs the PST-7 diagnostics-control pickup every tick — so the poll
    /// earns its keep independent of Focus. This is the SMALLEST of the four NRG
    /// levers: a leeway-coalesced pure-CPU wake per 60 s, off the DNS hot path, zero
    /// steady-state radio; the energy prize is unmeasurable and lengthening the
    /// interval regresses the ~60 s Focus-adoption promise and delays the PST-7
    /// pickup. Keep as-is.)
    private func startFocusConfigurationPoll() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.startFocusConfigurationPoll()
            }
            return
        }

        // Do NOT seed the watermark from disk here: the on-disk generation may already reflect a closed-app
        // switch the tunnel has NOT yet ADOPTED (config-leads-pointer), and seeding from it would suppress the
        // retry forever. Leave the watermark at whatever the startup snapshot LOAD adopted — the load advances
        // it at its adopt point — so the first tick reloads iff the on-disk generation is genuinely ahead of
        // what we actually adopted (Codex round 5).
        //
        // 10 s leeway: the ~60 s Focus-adoption promise tolerates the jitter, no tick is
        // phase-dependent (retry-until-adopt re-fires every tick regardless), and the
        // kernel can coalesce the wake. The poll itself is a hard invariant and stays.
        // (start() re-arms safely — the driver cancels any prior timer first.)
        focusConfigurationPollTimer.start(
            interval: Self.focusConfigurationPollInterval,
            leeway: .seconds(10)
        ) { [weak self] in
            self?.reloadSnapshotIfConfigurationGenerationAdvanced()
        }
    }

    private func stopFocusConfigurationPoll() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.stopFocusConfigurationPoll()
            }
            return
        }

        focusConfigurationPollTimer.stop()
    }

    /// Advance the Focus config-poll watermark to a generation the tunnel has ADOPTED — either via a full
    /// snapshot decode or because the resident snapshot already satisfies the reload. Guarded by the live
    /// reload-generation token (like `replaceSnapshot`) so a superseded load doesn't record. Passive
    /// bookkeeping only — never touches the recovery/fail-closed flow. A reload that fail-closed never
    /// reaches an adopt point, so the poll keeps retrying until the flipped artifact is adopted; a successful
    /// foreground/app-message reload advances it too, so the poll never redundantly reloads after one. (P4d.)
    private func advanceFocusConfigurationWatermark(toAdoptedGeneration adoptedGeneration: Int, ifCurrentReloadGeneration generation: UInt64) {
        dnsStateQueue.async { [weak self] in
            guard let self else { return }
            // dnsStateQueue-confined invariant (Kilo #29): the watermark advance and the in-flight-marker
            // clear are both enqueued on dnsStateQueue so they stay strictly FIFO-ordered (the snapshot-reload
            // correctness relies on it). Assert here so a future refactor that moves this mutation off the
            // queue trips instead of silently breaking the ordering.
            dispatchPrecondition(condition: .onQueue(self.dnsStateQueue))
            guard self.isCurrentSnapshotReloadGeneration(generation) else { return }
            self.lastObservedConfigurationGeneration = max(self.lastObservedConfigurationGeneration, adoptedGeneration)
        }
    }

    /// One poll tick (dnsStateQueue): if the on-disk configuration generation advanced past the last one the
    /// tunnel last ADOPTED, reload the snapshot. `force: true` because a Focus switch changed the published
    /// artifact + config, not the pause state (the only thing the non-force path acts on). Reuses the same
    /// reload entry the app's `reload-snapshot` provider message drives.
    ///
    /// The watermark (`lastObservedConfigurationGeneration`) is advanced by the snapshot LOAD on a successful
    /// adopt — NOT here. The extension writes app-configuration.json BEFORE flipping the artifact pointer
    /// (config-leads-pointer), so a poll can observe the new generation during that window; advancing the
    /// watermark on mere observation would skip the retry if this reload runs before the flip (loads the old
    /// pointer / fail-closes). Leaving the watermark to the adopt point means the poll keeps retrying every
    /// interval until the flipped artifact is actually adopted, and a foreground provider-message reload (which
    /// also adopts) advances it too, so the poll never redundantly reloads after a foreground switch (Codex P2).
    ///
    /// In-flight guard (round 5, Codex): never re-request while the latest reload is still running. Each
    /// request bumps `snapshotReloadGeneration`, which invalidates the in-flight load (and resets the DNS
    /// runtime), so a load/compile slower than the poll interval would be restarted forever and never adopt.
    /// We retry on the NEXT tick after it resolves — preserving the retry-until-adopted behavior (which is what
    /// correctly picks up the artifact-pointer FLIP in the config-leads-pointer window) without starving a slow
    /// load. The poll deliberately does NOT permanently bound a non-adopting generation: a same-generation
    /// pointer flip must still be retried (the extension cannot send a provider reload), so the only cost of a
    /// genuinely-unadoptable config is one in-flight-gated reload per interval until the generation advances or
    /// a publish makes it adoptable (Codex round 6).
    private func reloadSnapshotIfConfigurationGenerationAdvanced() {
        // PST-7 defense-in-depth: pick up a mid-session diagnostics-clear whose IPC message
        // was dropped, off the tunnel-start force-apply. `force: false` respects the durable
        // applied-marker (PST-1), so a re-run over an already-satisfied clear can't re-wipe
        // history accumulated since — the mtime gate then short-circuits every later tick
        // until a genuinely newer control request lands. Runs on THIS existing 60s poll's
        // dnsStateQueue (where the store is confined and the snapshot-loaded apply already
        // runs) — no new timer, no cadence change, and BEFORE the config-generation guards
        // so it fires every tick regardless of whether a Focus switch needs adopting.
        #if DEBUG || LAVA_QA_TOOLS
        EnergyCounters.shared.bump(.focusPollTick)   // NRG focus-poll lever: count the 60 s wakes
        EnergySignpost.event("focus-poll-tick")      // NRG Phase 2: mark the poll wake for Instruments
        EnergyCounters.shared.flushIfDue()           // NRG: flush the per-window counter summary (piggybacks this tick)
        #endif
        applyDiagnosticsControlIfNeeded(force: false)
        if diagnosticsPersistence.isDirty {
            persistDiagnosticsIfNeeded(force: true)
        }

        guard !snapshotReloadInFlight else { return }
        let onDiskGeneration = loadConfiguration()?.configurationGeneration ?? lastObservedConfigurationGeneration
        guard onDiskGeneration > lastObservedConfigurationGeneration else { return }
        requestSnapshotReload(reason: "focus-config-poll", force: true)
    }

    // MARK: - Fallback recovery & wedge recovery probes

    private func scheduleFallbackRecoverySmokeProbeIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleFallbackRecoverySmokeProbeIfNeeded()
            }
            return
        }

        guard DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: deviceDNSFallbackModeActive,
                consecutiveFallbackEvidenceCount: consecutiveQueryFallbackSuccessCount
              ),
              health.networkPathIsSatisfied,
              fallbackRecoverySmokeProbeWorkItem == nil
        else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.fallbackRecoverySmokeProbeWorkItem = nil
            guard DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: self.deviceDNSFallbackModeActive,
                consecutiveFallbackEvidenceCount: self.consecutiveQueryFallbackSuccessCount
            ) else {
                return
            }

            self.scheduleResolverSmokeProbeIfNeeded(reason: "device-dns-fallback-recovery")
        }

        fallbackRecoverySmokeProbeWorkItem = workItem
        dnsStateQueue.asyncAfter(
            deadline: .now() + DeviceDNSFallbackPolicy.fallbackRecoverySmokeProbeInterval,
            execute: workItem
        )
    }

    private func cancelFallbackRecoverySmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelFallbackRecoverySmokeProbe()
            }
            return
        }

        fallbackRecoverySmokeProbeWorkItem?.cancel()
        fallbackRecoverySmokeProbeWorkItem = nil
    }

    // Same-network DNS wedge recovery. When every resolver address is benched
    // (e.g. a transient burst of timeouts under heavy browsing backs them all
    // off) with no network or resolver-runtime change, nothing resets that
    // penalty box: queries stay failed-closed until the per-address backoff
    // expires AND organic traffic happens to retry, or the 300s routine probe
    // runs, or the user toggles protection (a fresh process starts with an empty
    // backoff — which is why a manual toggle recovers when in-place retries do
    // not). Self-reconnect is the heavier escalation, but it is rate-limited and
    // requires confirmed Connect-On-Demand, so it is suppressed exactly when the
    // user is most stuck. This lighter recovery resets the resolver backoff +
    // stale upstream connections and re-probes on a short cadence, with no
    // process restart and no per-query hammering (one re-probe per interval).
    // Cancelled by clearReconnectNeededActivitySuppression as soon as DNS recovers.
    private func scheduleResolverWedgeRecoveryProbeIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleResolverWedgeRecoveryProbeIfNeeded()
            }
            return
        }

        guard health.networkPathIsSatisfied else {
            return
        }

        // Decide the cadence mode + the delay up front so the already-armed check can compare
        // deadlines: the fast escalation (LAV-92) is for the UNCOVERED down-wedge (user offline now
        // → re-probe fast, ~2s doubling to the legacy 30s ceiling). A COVERED wedge (encrypted
        // fallback is carrying DNS; only the stale primary needs recapture) leaves the user online,
        // so it uses the gentle ceiling cadence AND holds the ramp counter at zero so a later real
        // down-wedge still starts fast.
        let now = Date()
        let coveredNow = ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: health, now: now)
        if coveredNow {
            resolverWedgeRecoveryAttempt = 0
        }
        let delay: TimeInterval
        if coveredNow {
            delay = resolverWedgeRecoveryCadence.maxInterval
        } else {
            // Floor the fast ramp at the recovery probe's ACTUAL smoke-probe timeout, computed the
            // SAME way the probe computes it (transport + device-DNS-fallback availability). A probe
            // that can hang to its timeout — an encrypted primary OR a fallback-capable plain
            // primary that runs primary-then-fallback — must not be re-armed sooner, or the new
            // probe bumps resolverSmokeProbeGeneration mid-flight, discards the in-flight result,
            // and churns the session before it can recover (Codex P2 r3/r4). Since every re-arm
            // happens at-or-after the wedge fired and delay >= that timeout, the next probe never
            // fires before the in-flight one completes. A fast local probe (recovery timeout) still
            // effectively gets the short ramp.
            let rampDelay = resolverWedgeRecoveryCadence.delay(forAttempt: resolverWedgeRecoveryAttempt)
            let probeResolverConfiguration = currentResolverRuntimeConfiguration(
                ignoresDeviceDNSFallbackMode: true,
                allowsQueryFallback: false
            )
            let canUseDeviceDNSFallback = currentAppConfiguration().fallbackToDeviceDNS
                && probeResolverConfiguration.transport != .deviceDNS
                && !probeResolverConfiguration.deviceDNSFallbackAddresses.isEmpty
            let probeTimeout = TimeInterval(Self.smokeProbeTimeoutSeconds(
                reason: "resolver-wedge-recovery",
                transport: probeResolverConfiguration.transport,
                canUseDeviceDNSFallback: canUseDeviceDNSFallback
            ))
            delay = max(rampDelay, probeTimeout)
        }
        let deadline = now.addingTimeInterval(delay)

        if let armedDeadline = resolverWedgeRecoveryArmedDeadline {
            // A probe is already armed. Keep it UNLESS:
            //  * the cadence MODE changed (covered<->uncovered) — re-arm on the correct cadence for
            //    the new state: coverage lapsing speeds an offline user up to the fast ramp, and
            //    coverage engaging slows an online user back to the gentle cadence so a fast probe
            //    can't tear down a fallback that's keeping DNS working (Codex P2 r5); OR
            //  * within the same mode, a strictly-sooner probe is now warranted.
            // An equal/later same-mode deadline keeps the pending probe, so repeated calls never
            // churn it. (Codex P2 r1/r2/r5.)
            let modeChanged = resolverWedgeRecoveryArmedCovered != coveredNow
            guard modeChanged || deadline < armedDeadline else {
                return
            }
            resolverWedgeRecoveryWorkItem?.cancel()
            resolverWedgeRecoveryWorkItem = nil
            resolverWedgeRecoveryArmedDeadline = nil
        }

        // Committing to arm: count this uncovered probe toward the escalating ramp.
        if !coveredNow {
            resolverWedgeRecoveryAttempt += 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.resolverWedgeRecoveryWorkItem = nil
            // The armed probe has fired; clear its deadline so the loop's re-arm (via the
            // smoke-probe-failure path) isn't blocked by a now-past deadline.
            self.resolverWedgeRecoveryArmedDeadline = nil

            // Re-confirm the primary is still wedged before disrupting the runtime.
            // THREE independent signals can mean "primary still wedged"; honour ANY:
            //   * the assessment derived from `health` says `.reconnect` (DNS down), OR
            //   * the wedge marker (`reconnectNeededSince`, via currentDeviceResolverWedged)
            //     is still held — the masked-healthy DOWN wedge: a fallback-carried success
            //     clears health's failure counters so the assessment reads healthy, but the
            //     fallback branch in recordUpstreamResult HOLDS the marker, OR
            //   * the assessment says `.usingEncryptedFallback` — the COVERED wedge, where
            //     DoH/DoT is actively carrying DNS for a transition-stale Device-DNS primary.
            //     This signal is derived purely from `health` (the fallback serving timestamp
            //     + smoke state) and NEVER stamps `reconnectNeededSince`, so it does not flip
            //     `treatsResolverRejectionAsFallbackTrigger` or bypass authoritative
            //     SERVFAIL/REFUSED — the exact reason recovery-in-place could not reuse the
            //     marker. It accelerates recapture from the routine cadence to this one.
            // A genuine recovery or lifecycle reset clears every signal (and cancels this
            // work item), so this still no-ops on an actually-healthy tunnel.
            let now = Date()
            let assessment = ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: self.health,
                now: now
            )
            let isDownWedge = assessment.primaryAction == .reconnect || self.currentDeviceResolverWedged()
            // Read the covered-coverage bit from the explicit named predicate rather than
            // string-matching the full assessment's severity — same source of truth, no re-derivation.
            // isCoveredWedge (rejection-gated) still drives the recapture REASON + the churn-skip;
            // isCarryingFallback (= covering MINUS the rejected==0 gate, but still requires a failed
            // smoke-probe context) keeps the loop ALIVE so a covered recapture probe that gets
            // rejected doesn't stall the cadence (the marker is unstamped). It does NOT fire for a
            // one-off fallback-carried query with no failed probe.
            let isCoveredWedge = ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: self.health, now: now)
            let isCarryingFallback = ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: self.health, now: now)
            guard self.health.networkPathIsSatisfied, isDownWedge || isCarryingFallback else {
                // The wedge cleared without a logged recovery cancelling us (e.g. a covered episode
                // whose coverage lapsed to a non-reconnect state, or a config/identity change reset
                // the runtime). End the episode so a later wedge restarts the fast ramp rather than
                // inheriting this episode's backed-off delay.
                self.resolverWedgeRecoveryAttempt = 0
                return
            }

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "resolver-wedge-recovery", details: [
                "reason": self.health.lastFailureReason ?? "dns-wedged",
                "severity": assessment.severity.diagnosticLabel,
                "mode": isCoveredWedge ? "encrypted-fallback-covered" : "down-wedge",
                "consecutiveUpstreamFailureCount": "\(self.health.consecutiveUpstreamFailureCount)"
            ])

            // Re-read the device resolvers (the transition-stale primary's addresses may
            // have changed on the new network; best-effort — in-tunnel capture was observed
            // empty in the 1758 log, the dedicated capture-retry is the real refresh) and
            // clear the backoff penalty box so the re-probe — and organic queries — get a
            // fresh attempt at the primary. The smoke probe honours backoff (the orchestrator
            // gates EVERY purpose on it), so without this reset a backed-off primary would
            // never be re-tested and could never recapture.
            self.refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "resolver-wedge-recovery")
            self.resolverBackoffStateQueue.sync {
                self.resolverBackoffPolicy.reset()
            }
            // Churn the encrypted transports' sessions ONLY for a DNS-DOWN wedge that the
            // encrypted fallback is NOT currently carrying. In the COVERED state — including
            // the OVERLAP where a stale DOWN-wedge marker was stamped (an uncovered `.reconnect`
            // moment) before coverage engaged and has not yet been cleared — those very DoH/DoT
            // sessions are actively serving DNS, so resetting them would disrupt the fallback
            // keeping the user online; a Device-DNS primary recapture does not need it (its
            // refresh is the device-DNS re-read above; the smoke re-probe below detects
            // recapture). `isCoveredWedge` tracks the fallback actively serving, so it suppresses
            // the churn even while the marker is still held. Once coverage genuinely lapses the
            // next pass (now !isCoveredWedge) takes the clean-slate reset.
            if isDownWedge, !isCoveredWedge {
                self.resetResolverTransientState()
            }
            // A failed re-probe re-arms this recovery (down wedge: via
            // appendReconnectNeededIfPolicyRequiresReconnect / the marker; covered wedge:
            // via the covered re-arm in the smoke-probe-failure path), so the loop
            // self-sustains at the wedge cadence until the primary recaptures (the success
            // path cancels it).
            self.scheduleResolverSmokeProbeIfNeeded(reason: isCoveredWedge ? "covered-primary-recapture" : "resolver-wedge-recovery")
        }

        resolverWedgeRecoveryWorkItem = workItem
        resolverWedgeRecoveryArmedDeadline = deadline
        resolverWedgeRecoveryArmedCovered = coveredNow
        dnsStateQueue.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func cancelResolverWedgeRecoveryProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelResolverWedgeRecoveryProbe()
            }
            return
        }

        resolverWedgeRecoveryWorkItem?.cancel()
        resolverWedgeRecoveryWorkItem = nil
        resolverWedgeRecoveryArmedDeadline = nil
        // End of the wedge episode — the next one restarts the fast escalation ramp.
        resolverWedgeRecoveryAttempt = 0
    }

    // Bounded device-DNS capture retry (dns-recovery optimization C). On a
    // resolver-changing handoff the in-tunnel capture can come back empty (iOS
    // masking the real resolvers behind the tunnel's own 10.255.0.1), so
    // preserveOnEmptyCapture strands a Device-DNS user on the previous network's
    // unreachable resolvers — the silent wedge UR-37 reported. Re-read the system
    // resolvers on a short cadence until the capture is non-empty, then adopt the
    // fresh addresses and reset the runtime so live queries use them. Only runs
    // when the active config actually depends on Device DNS (primary or fallback)
    // and the path is satisfied; superseded on the next handoff/wake/lifecycle
    // reset. A fully-masked network exhausts the cap and falls through to the
    // wedge-recovery probe + on-demand-gated self-reconnect, which are unchanged.
    // MARK: - Device-DNS capture retry

    private func scheduleDeviceDNSCaptureRetryIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleDeviceDNSCaptureRetryIfNeeded(reason: reason)
            }
            return
        }

        cancelDeviceDNSCaptureRetry()

        guard health.networkPathIsSatisfied, currentConfigurationDependsOnDeviceDNS() else {
            return
        }

        // A wake alone is not evidence the mask lifted: the one-shot wake re-read
        // (refreshDeviceDNSResolverAddressesOnDNSQueue) already samples the current
        // network each wake, so restarting the full retry cycle within the cooldown
        // of an exhausted-still-masked cycle only repeats reads that just failed.
        // Any non-wake reason means a real change — clear the cooldown and retry.
        switch deviceDNSCaptureRetryCycle.noteScheduleRequest(isWake: reason == "wake") {
        case .suppress(let logOnce):
            if logOnce {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-capture-retry-suppressed", details: [
                    "reason": reason
                ])
            }
            return
        case .start:
            armDeviceDNSCaptureRetry(reason: reason)
        }
    }

    private func armDeviceDNSCaptureRetry(reason: String) {
        deviceDNSCaptureRetryCycle.armAttempt(
            after: DeviceDNSFallbackPolicy.deviceDNSCaptureRetryInterval
        ) { [weak self] in
            self?.runDeviceDNSCaptureRetry(reason: reason)
        }
    }

    private func runDeviceDNSCaptureRetry(reason: String) {
        // The network or resolver config may have moved on since this was armed
        // (each handoff/wake supersedes via scheduleDeviceDNSCaptureRetryIfNeeded);
        // re-confirm before disturbing the runtime.
        guard health.networkPathIsSatisfied, currentConfigurationDependsOnDeviceDNS() else {
            return
        }

        let attemptNumber = deviceDNSCaptureRetryCycle.noteAttemptRan()
        let previousAddresses = deviceDNSResolverAddresses
        let captured = Self.currentSystemDNSServerAddresses()
        deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
            current: deviceDNSResolverAddresses,
            captured: captured,
            preserveOnEmptyCapture: true
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-capture-retry", details: [
            "reason": reason,
            "attempt": "\(attemptNumber)",
            "capturedCount": "\(captured.count)",
            "activeCount": "\(deviceDNSResolverAddresses.count)"
        ])

        if !captured.isEmpty {
            // The mask lifted: we have this network's resolvers. If they actually
            // changed, reset the resolver runtime so in-flight + future queries use
            // them (mirrors the settle path) and fire a confirming smoke probe; a
            // genuine recovery then clears the wedge marker. Either way, stop
            // retrying — the capture is no longer masked.
            deviceDNSCaptureRetryCycle.noteCaptureSucceeded(
                addressesChanged: deviceDNSResolverAddresses != previousAddresses
            )
            if deviceDNSResolverAddresses != previousAddresses {
                let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
                let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
                    identifier: resolverIdentifier,
                    reason: "device-dns-recaptured-on-retry",
                    force: true
                )
                writeServerFailures(for: pendingResponses, reason: "device-dns-recaptured-on-retry")
                scheduleResolverSmokeProbeIfNeeded(reason: "device-dns-recaptured-on-retry")
            }
            return
        }

        guard deviceDNSCaptureRetryCycle.shouldContinue(capturedNonEmpty: false) else {
            // Capture stayed masked across the whole window — this is a genuine
            // resolver-changing handoff, not a transient mask. The previous network's
            // resolvers are now unreachable; keeping them serves a dead address, so
            // every query burns a multi-second timeout — the "slow guide" limp the
            // field log showed (~90s to wedge-recovery).
            //
            // Whether dropping them to empty is an IMPROVEMENT depends on whether
            // anything catches the queries afterward. Empty device DNS makes
            // resolveDeviceDNS return a fast structured `deviceDNSUnavailable`:
            //   * WITH a per-query encrypted fallback configured (the alt guide):
            //     dropping is strictly better — every organic query routes straight to
            //     the encrypted fallback (resolveUpstream: shouldFallbackToEncrypted +
            //     no usable primary answer) instead of waiting on the dead primary
            //     first. So drop.
            //   * NO encrypted fallback (Device-DNS-ONLY): `deviceDNSUnavailable` is
            //     deliberately NOT in restartFailureReasons (it is the cold-start
            //     "wait for capture" state), so dropping would leave the no-fallback
            //     masked handoff fail-closed WITHOUT escalating — removing the
            //     slow-but-real restart recovery the stale resolver's restart-worthy
            //     timeout/send-failed still drives (Codex P1 on #110). So PRESERVE the
            //     stale resolver here and let the existing self-reconnect recovery fire.
            //     The prompt, controlled re-capture for this no-fallback case is Track 4
            //     (the gated cold-restart hooked in below) — the preserved stale resolver is
            //     the backstop if that restart is throttled/declined (its restart-worthy
            //     timeouts still drive the slow wedge path).
            // `currentResolverRuntimeConfiguration()` builds with allowsQueryFallback,
            // so `encryptedFallback != nil` is exactly the organic-query routing
            // condition, and it is independent of whether the addresses are empty.
            let routesToEncryptedFallback = currentResolverRuntimeConfiguration().encryptedFallback != nil
            let previousAddresses = deviceDNSResolverAddresses
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: [],
                preserveOnEmptyCapture: !routesToEncryptedFallback
            )
            let droppedStale = deviceDNSResolverAddresses != previousAddresses
            deviceDNSCaptureRetryCycle.noteExhausted()
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-capture-retry-exhausted", details: [
                "reason": reason,
                "attempts": "\(deviceDNSCaptureRetryCycle.attemptsMade)",
                "routesToEncryptedFallback": "\(routesToEncryptedFallback)",
                "droppedStale": "\(droppedStale)"
            ])
            Self.recordIncident(.deviceDNSRecaptureExhausted, reason: reason)

            // Make the drop take effect on in-flight + future queries (the cached
            // runtime still points at the stale resolver otherwise), then fire a
            // confirming probe so the policy sees the unavailable primary now rather
            // than on the next routine cadence. Mirrors the recapture path above.
            if droppedStale {
                let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
                let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
                    identifier: resolverIdentifier,
                    reason: "device-dns-stale-dropped-on-exhaustion",
                    force: true
                )
                writeServerFailures(for: pendingResponses, reason: "device-dns-stale-dropped-on-exhaustion")
                scheduleResolverSmokeProbeIfNeeded(reason: "device-dns-stale-dropped-on-exhaustion")
            }

            // Track 4 — no-fallback handoff: cold restart is the ONLY thing that re-captures
            // the new network's resolver (Phase 0), so escalate PROMPTLY here rather than
            // waiting on the 30s wedge-recovery loop + smoke-streak climb. Gated/capped
            // inside (own ceiling + on-demand + Track-1 path guard); declines arm the
            // in-place wedge probe. The fallback case (routesToEncryptedFallback) must NOT
            // restart — Option-A keeps serving over the encrypted path (Track 3).
            if !routesToEncryptedFallback {
                promptDeviceDNSRecaptureRestartIfPolicyAllows(now: Date())
            }
            return
        }

        armDeviceDNSCaptureRetry(reason: reason)
    }

    private func cancelDeviceDNSCaptureRetry() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelDeviceDNSCaptureRetry()
            }
            return
        }

        deviceDNSCaptureRetryCycle.cancelPendingAttempt()
    }

    // True when live queries can route through Device DNS — either it is the
    // primary transport or it is the configured fallback — so a stale/masked
    // capture would wedge resolution and a re-capture is worth retrying. A pure
    // DoH/DoT/DoQ config with no device-DNS fallback never depends on the capture,
    // so the retry no-ops for it.
    private func currentConfigurationDependsOnDeviceDNS() -> Bool {
        let resolverConfiguration = currentResolverRuntimeConfiguration(
            ignoresDeviceDNSFallbackMode: true,
            allowsQueryFallback: false
        )
        return resolverConfiguration.transport == .deviceDNS
            || currentAppConfiguration().fallbackToDeviceDNS
    }

    // MARK: - Smoke probe scheduling & result application

    private func scheduleResolverSmokeProbeIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleResolverSmokeProbeIfNeeded(reason: reason)
            }
            return
        }

        guard health.networkPathIsSatisfied else {
            return
        }

        // NRG-3a: the routine tick — and ONLY the routine tick; every other reason
        // (wedge, fallback-recovery, settle, config-change, startTunnel) stays
        // unconditional — skips the wire probe when equivalent evidence already
        // exists. "Equivalent" requires ALL of: a fully-healthy ladder (any nonzero
        // streak, active fallback mode, or armed wedge marker means mid-incident,
        // where there is no equivalence and skipping would freeze the LAV-87
        // escalation), and acceptance-checked primary evidence younger than one
        // probe interval. The staleness guarantee is unchanged: real traffic that
        // passed the probe's own acceptance check IS fresher proof than a probe.
        if reason == "periodic-health-check",
           health.consecutiveRejectedSmokeResponseCount == 0,
           health.consecutiveDNSSmokeProbeFailureCount == 0,
           health.consecutiveUpstreamFailureCount == 0,
           !deviceDNSFallbackModeActive,
           reconnectNeededSince == nil,
           let evidenceAt = lastAcceptedPrimaryEvidenceAt {
            // Future-dated evidence (a backward wall-clock jump after the stamp) must
            // NOT skip: a negative age would satisfy an upper bound alone until the
            // clock caught up — indefinitely suppressing routine probes. Out-of-range
            // evidence in either direction just means "probe normally".
            let evidenceAge = Date().timeIntervalSince(evidenceAt)
            if evidenceAge >= 0, evidenceAge <= Self.resolverSmokeProbeInterval {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-skipped", details: [
                    "reason": reason,
                    "evidenceAgeMs": "\(Int(evidenceAge * 1_000))"
                ])
                #if DEBUG || LAVA_QA_TOOLS
                EnergyCounters.shared.bump(.smokeProbeSkip)   // NRG smoke-probe lever: NRG-3a suppressed the wire query
                #endif
                return
            }
        }

        let resolverConfiguration = currentResolverRuntimeConfiguration(
            ignoresDeviceDNSFallbackMode: true,
            allowsQueryFallback: false
        )
        let canUseDeviceDNSFallback = currentAppConfiguration().fallbackToDeviceDNS
            && resolverConfiguration.transport != .deviceDNS
            && !resolverConfiguration.deviceDNSFallbackAddresses.isEmpty
        #if DEBUG || LAVA_QA_TOOLS
        EnergyCounters.shared.bump(.smokeProbeWire)   // NRG smoke-probe lever: this probe hits the wire (radio wake)
        EnergySignpost.event("smoke-probe-wire")      // NRG Phase 2: mark the radio wake for Instruments
        #endif
        resolverSmokeProbeGeneration += 1
        let generation = resolverSmokeProbeGeneration
        // Rotate the canary domain per probe so a single blocked/hijacked domain
        // can't sustain a false "unhealthy" verdict (a different domain's success
        // resets the consecutive-failure count); a resolver that refuses them all
        // still escalates.
        let probeDomain = DNSResolverSmokeProbe.probeDomain(forSequence: generation)
        let query = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: probeDomain
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-begin", details: [
            "reason": reason,
            "transport": resolverConfiguration.transport.rawValue,
            "canUseDeviceDNSFallback": "\(canUseDeviceDNSFallback)"
        ])

        runResolverSmokeProbeWork { [weak self] finish in
            guard let self else {
                finish()
                return
            }

            let timeout = ResolverSmokeProbeTimeout { [weak self] in
                guard let self else {
                    finish()
                    return
                }

                self.dnsStateQueue.async { [weak self] in
                    guard let self else {
                        finish()
                        return
                    }

                    let timeoutResult = self.resolverSmokeProbeTimeoutResult(
                        resolverConfiguration: resolverConfiguration
                    )
                    self.completeResolverSmokeProbeResult(
                        generation: generation,
                        reason: reason,
                        primaryResult: timeoutResult,
                        primarySucceeded: false,
                        fallbackResult: nil,
                        fallbackSucceeded: false
                    )
                    finish()
                }
            }
            timeout.schedule(on: dnsStateQueue, timeoutSeconds: Self.smokeProbeTimeoutSeconds(
                reason: reason,
                transport: resolverConfiguration.transport,
                canUseDeviceDNSFallback: canUseDeviceDNSFallback
            ))

            self.resolvePrimaryUpstream(query, resolverConfiguration: resolverConfiguration, purpose: .smokeProbe) { [weak self] primaryResult in
                guard let self else {
                    timeout.cancel()
                    finish()
                    return
                }

                let primarySucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse(
                    primaryResult.response,
                    matching: query
                )

                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-primary-result", details: [
                    "reason": reason,
                    "primaryAccepted": "\(primarySucceeded)",
                    "primaryHasResponse": "\(primaryResult.response != nil)",
                    "primaryOutcome": primaryResult.failureSummary ?? "success",
                    "transport": primaryResult.transport.rawValue,
                    "resolver": primaryResult.successfulResolverAddress ?? primaryResult.attempts.last?.address ?? "nil"
                ])

                guard !primarySucceeded, canUseDeviceDNSFallback else {
                    timeout.cancel()
                    self.dnsStateQueue.async { [weak self] in
                        self?.completeResolverSmokeProbeResult(
                            generation: generation,
                            reason: reason,
                            primaryResult: primaryResult,
                            primarySucceeded: primarySucceeded,
                            fallbackResult: nil,
                            fallbackSucceeded: false
                        )
                    }
                    finish()
                    return
                }

                self.resolverQueue.async { [weak self] in
                    guard let self else {
                        timeout.cancel()
                        finish()
                        return
                    }

                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-fallback-begin", details: [
                        "reason": reason,
                        "resolverCount": "\(resolverConfiguration.deviceDNSFallbackAddresses.count)"
                    ])

                    let fallbackResult = self.resolveDeviceDNS(
                        query,
                        resolverAddresses: resolverConfiguration.deviceDNSFallbackAddresses
                    )
                    let fallbackSucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse(
                        fallbackResult.response,
                        matching: query
                    )

                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-fallback-result", details: [
                        "reason": reason,
                        "fallbackAccepted": "\(fallbackSucceeded)",
                        "fallbackHasResponse": "\(fallbackResult.response != nil)",
                        "fallbackOutcome": fallbackResult.failureSummary ?? "success",
                        "resolver": fallbackResult.successfulResolverAddress ?? fallbackResult.attempts.last?.address ?? "nil"
                    ])

                    timeout.cancel()
                    self.dnsStateQueue.async { [weak self] in
                        self?.completeResolverSmokeProbeResult(
                            generation: generation,
                            reason: reason,
                            primaryResult: primaryResult,
                            primarySucceeded: primarySucceeded,
                            fallbackResult: fallbackResult,
                            fallbackSucceeded: fallbackSucceeded
                        )
                    }
                    finish()
                }
            }
        }
    }

    private func resolverSmokeProbeTimeoutResult(
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> DNSResolutionResult {
        DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(
                    address: resolverConfiguration.cacheIdentifier,
                    outcome: .timeout,
                    transport: resolverConfiguration.transport
                )
            ],
            transport: resolverConfiguration.transport,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false
        )
    }

    private func completeResolverSmokeProbeResult(
        generation: Int,
        reason: String,
        primaryResult: DNSResolutionResult,
        primarySucceeded: Bool,
        fallbackResult: DNSResolutionResult?,
        fallbackSucceeded: Bool
    ) {
        guard generation == resolverSmokeProbeGeneration else {
            return
        }

        applyResolverSmokeProbeResult(
            generation: generation,
            reason: reason,
            primaryResult: primaryResult,
            primarySucceeded: primarySucceeded,
            fallbackResult: fallbackResult,
            fallbackSucceeded: fallbackSucceeded
        )

        if resolverSmokeProbeGeneration == generation {
            resolverSmokeProbeGeneration += 1
        }
    }

    private func applyResolverSmokeProbeResult(
        generation: Int,
        reason: String,
        primaryResult: DNSResolutionResult,
        primarySucceeded: Bool,
        fallbackResult: DNSResolutionResult?,
        fallbackSucceeded: Bool
    ) {
        guard generation == resolverSmokeProbeGeneration else {
            return
        }

        let now = Date()
        let wasDeviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        let previousDNSSmokeProbeSucceeded = health.lastDNSSmokeProbeSucceeded
        health.lastDNSSmokeProbeAt = now
        health.lastDNSSmokeProbeSucceeded = primarySucceeded || fallbackSucceeded

        if primarySucceeded {
            consecutiveQueryFallbackSuccessCount = 0
            deviceDNSFallbackModeActive = false
            // Primary smoke probe passed → the wedge is over even if no organic primary
            // query has arrived yet, so end the coalesced fallback episode here (the
            // recovers-via-smoke-probe case, incl. a sub-wedge blip that never set the
            // wedge marker, so `logConnectivityRecoveredIfWedged` alone would miss it).
            clearEncryptedFallbackLogThrottle()
            health.deviceDNSFallbackModeActive = false
            health.lastDeviceDNSFallbackActivatedAt = nil
            health.dnsSmokeProbeSuccessCount += 1
            health.consecutiveDNSSmokeProbeFailureCount = 0
            // The primary is proven healthy, so the encrypted fallback is no longer covering
            // anything — clear its serving timestamp so a stale (<30s) success from before this
            // recovery can't cover a brand-new outage's probe. (The connectivity policy keys
            // coverage on an absolute freshness window, so clearing on recovery is what scopes
            // the signal to the CURRENT outage. Mirrors the forwarding-success clear below.)
            health.lastEncryptedFallbackSuccessAt = nil
            // An ACCEPTED primary smoke probe (known-good domain, acceptance-checked) is the
            // authoritative proof the primary is healthy, so it is the only place that clears
            // the LAV-87 rejected-response streak — the organic forwarding path must not
            // (a REFUSED reply counts as `didResolve` there). See recordUpstreamResult.
            health.consecutiveRejectedSmokeResponseCount = 0
            health.rejectedSmokeResponseResolverIdentity = nil
            // NRG-3a: an accepted primary probe is acceptance-checked evidence — but ONLY
            // when its completion is not in lockstep with the periodic timer, or the skip
            // would stretch the idle cadence to ~600s effective (the honesty-budget
            // widening the founder rejected). Two such reasons: the routine tick itself
            // (its success completes moments after its own tick, self-feeding every
            // subsequent tick — Codex round 1) and the startTunnel probe (it runs
            // immediately before startPeriodicResolverSmokeProbe arms the timer, so its
            // evidence is fractionally younger than the interval at the FIRST tick and an
            // idle session would go ~600s before its first routine wire probe — Codex
            // round 5). Settle/wedge-recovery/config-change probes keep the timer's
            // original phase, so their evidence making the following tick redundant is
            // the intended saving.
            if reason != "periodic-health-check", reason != "startTunnel" {
                lastAcceptedPrimaryEvidenceAt = now
            }
            health.lastFailureReason = nil
            health.lastResolverAddress = primaryResult.successfulResolverAddress
            health.lastResolverTransport = primaryResult.transport
            if primaryResult.transport == .dnsOverHTTPS, let negotiatedDoHProtocol = primaryResult.negotiatedDoHProtocol {
                health.lastDoHHTTPVersion = negotiatedDoHProtocol
            }
            health.consecutiveUpstreamFailureCount = 0
            // In-place recovery via the (wedge-recovery / settle) smoke probe — the
            // common self-heal path that never reaches recordUpstreamResult. Record
            // it before clearing the wedge state so the recovery isn't silent.
            logConnectivityRecoveredIfWedged(transport: primaryResult.transport, verifiedBy: "smoke-probe", now: now)
            // A confirmed primary recovery — credit a productive pre-launch self-reconnect
            // (Track 4). Decoupled from the wedge marker above (which the restart's process
            // kill wipes) so a cold-restart recapture is credited on the relaunched process.
            creditProductiveSelfReconnectIfPending(now: now)
            clearReconnectNeededActivitySuppression()
            cancelFallbackRecoverySmokeProbe()
            let pendingResponses = wasDeviceDNSFallbackModeActive
                ? collectPendingResponsesAndResetResolverRuntime(
                    identifier: currentResolverRuntimeConfiguration().cacheIdentifier,
                    reason: "device-dns-fallback-recovered",
                    force: true
                )
                : []
            markHealthUpdated()
            if wasDeviceDNSFallbackModeActive {
                appendNetworkActivity(event: .deviceDNSFallbackRecovered, now: now)
            } else if reason == "network-path-changed" || previousDNSSmokeProbeSucceeded == false {
                appendNetworkActivity(
                    event: .dnsSmokeProbeSucceeded(
                        resolver: currentAppConfiguration().resolverPreset.displayName,
                        transport: primaryResult.transport,
                        dohHTTPVersion: primaryResult.negotiatedDoHProtocol
                    ),
                    now: now
                )
            }
            scheduleProtectionNotificationIfNeeded(now: now)
            writeServerFailures(for: pendingResponses, reason: "device-dns-fallback-recovered")
            #if LAVA_QA_TOOLS
            logQAConnectivityAssessmentIfNeeded(reason: "dns-smoke-probe-success", now: now)
            #endif

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-success", details: [
                "reason": reason,
                "transport": primaryResult.transport.rawValue,
                "resolver": primaryResult.successfulResolverAddress ?? "nil",
                "dohHTTPVersion": primaryResult.negotiatedDoHProtocol ?? "nil"
            ])
            return
        }

        if fallbackSucceeded, let fallbackResult {
            health.dnsSmokeProbeSuccessCount += 1
            health.consecutiveDNSSmokeProbeFailureCount = 0
            consecutiveQueryFallbackSuccessCount = DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
                currentCount: consecutiveQueryFallbackSuccessCount,
                primaryResolverWasAttempted: primaryResult.hasFallbackActivationEvidence
            )
            if DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                consecutiveQueryFallbackSuccesses: consecutiveQueryFallbackSuccessCount
            ) {
                deviceDNSFallbackModeActive = true
                health.deviceDNSFallbackModeActive = true
                if !wasDeviceDNSFallbackModeActive {
                    health.lastDeviceDNSFallbackActivatedAt = now
                    health.deviceDNSFallbackActivationCount += 1
                } else if health.lastDeviceDNSFallbackActivatedAt == nil {
                    health.lastDeviceDNSFallbackActivatedAt = now
                }
            } else {
                health.deviceDNSFallbackModeActive = false
            }
            health.lastFailureReason = nil
            health.lastResolverAddress = fallbackResult.successfulResolverAddress
            health.lastResolverTransport = .deviceDNS
            health.consecutiveUpstreamFailureCount = 0
            // Device-DNS fallback now resolving after a wedge counts as recovery
            // (DNS flows again); record it before clearing the wedge state.
            logConnectivityRecoveredIfWedged(transport: .deviceDNS, verifiedBy: "smoke-probe", now: now)
            // Confirmed device-DNS recovery — credit a productive pre-launch self-reconnect (Track 4).
            creditProductiveSelfReconnectIfPending(now: now)
            clearReconnectNeededActivitySuppression()
            let pendingResponses = deviceDNSFallbackModeActive
                ? collectPendingResponsesAndResetResolverRuntime(
                    identifier: currentResolverRuntimeConfiguration().cacheIdentifier,
                    reason: "device-dns-fallback-activated",
                    force: true
                )
                : []
            markHealthUpdated()
            if deviceDNSFallbackModeActive, !wasDeviceDNSFallbackModeActive {
                appendNetworkActivity(event: .deviceDNSFallbackActivated(reason: reason), now: now)
            }
            scheduleFallbackRecoverySmokeProbeIfNeeded()
            if deviceDNSFallbackModeActive {
                scheduleProtectionNotificationIfNeeded(now: now)
            }
            persistHealthIfNeeded(force: true)
            writeServerFailures(for: pendingResponses, reason: "device-dns-fallback-activated")
            #if LAVA_QA_TOOLS
            logQAConnectivityAssessmentIfNeeded(
                reason: deviceDNSFallbackModeActive ? "device-dns-fallback-activated" : "device-dns-fallback-candidate",
                now: now
            )
            #endif

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-device-fallback", details: [
                "reason": reason,
                "evidenceCount": "\(consecutiveQueryFallbackSuccessCount)",
                "fallbackModeActive": "\(deviceDNSFallbackModeActive)",
                "resolver": fallbackResult.successfulResolverAddress ?? "nil"
            ])
            return
        }

        health.dnsSmokeProbeFailureCount += 1
        health.consecutiveDNSSmokeProbeFailureCount += 1
        if wasDeviceDNSFallbackModeActive {
            deviceDNSFallbackModeActive = false
            health.deviceDNSFallbackModeActive = false
            health.lastDeviceDNSFallbackActivatedAt = nil
            consecutiveQueryFallbackSuccessCount = 0
            cancelFallbackRecoverySmokeProbe()
        }
        // A response that arrived but failed acceptance (rcode != 0, no answers, or
        // a question mismatch) means the resolver is REACHABLE but unusable — e.g. a
        // stale off-network resolver refusing queries, or a hijacked/blocked answer.
        // Its last attempt's wire outcome is `.success`, so failureSummary would
        // record the nonsensical "success" — which is NOT a restart-worthy reason,
        // so the connectivity policy mis-read it as healthy and never engaged
        // recovery (the 1941 "DNS smoke probe failed: success" wedge). Classify it
        // as `rejected-response` (a restart-worthy reason) so recovery engages.
        let primaryReason: String
        if primaryResult.response != nil {
            primaryReason = "rejected-response"
        } else {
            primaryReason = primaryResult.failureSummary ?? fallbackResult?.failureSummary ?? "dns-smoke-failed"
        }
        health.lastFailureReason = primaryReason
        health.lastUpstreamFailureAt = now
        health.consecutiveUpstreamFailureCount += 1
        health.lastResolverAddress = primaryResult.successfulResolverAddress ?? primaryResult.attempts.last?.address
        health.lastResolverTransport = primaryResult.transport
        // Resolver-identity-scoped rejected-response streak (LAV-87): a reachable-but-
        // rejected answer from the SAME resolver is strong evidence it is hijacking /
        // stale. Kept out of the generic streak's reset paths (network-change recovery,
        // settle/recapture, wake) so it survives the churn that keeps
        // `consecutiveDNSSmokeProbeFailureCount` under the reconnect threshold on a
        // roaming network; cleared only by an accepted primary smoke-probe success or a
        // resolver change (NOT the organic forwarding path — a REFUSED counts as resolved there).
        // Keyed on the PRIMARY identity, mirroring the clear site in
        // collectPendingResponsesAndResetResolverRuntime: the full runtime cacheIdentifier also
        // folds in `|fallback:device:<captured addresses>`, which churns on every handoff /
        // capture-retry adoption while fallbackToDeviceDNS is enabled (the default) — counting
        // under it re-scopes the streak to 1 on each flap, pinning the escalation below the
        // reconnect threshold for a steadily-rejecting primary (the exact churn LAV-87 must survive).
        // The primary identity is also taken MODE-INSENSITIVELY (COH-1): when device-DNS-fallback
        // MODE is active, `primaryCacheIdentifier` folds in the *effective* transport (`.deviceDNS`
        // + device addresses) instead of the configured encrypted endpoint, so a mode flip on a
        // rejecting DoH primary would otherwise re-scope the streak — a second DNS-1 channel.
        if primaryReason == "rejected-response" {
            let rejectedResolverIdentity = currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true).primaryCacheIdentifier
            if health.rejectedSmokeResponseResolverIdentity == rejectedResolverIdentity {
                health.consecutiveRejectedSmokeResponseCount += 1
            } else {
                health.rejectedSmokeResponseResolverIdentity = rejectedResolverIdentity
                health.consecutiveRejectedSmokeResponseCount = 1
                health.rejectedSmokeResponseRescopeCount += 1
            }
            // Ledger record exactly at the policy's own escalation bar (== not >=, so a
            // sustained hijack writes ONE record per episode, not one per probe).
            if health.consecutiveRejectedSmokeResponseCount
                == ProtectionConnectivityPolicy.sustainedRejectedSmokeResponseThreshold {
                Self.recordIncident(.rejectedResponseStreak, reason: "rejected-response", now: now)
            }
        }
        markHealthUpdated()
        let failureReason = health.lastFailureReason ?? "dns-smoke-failed"
        appendNetworkActivity(event: .dnsSmokeProbeFailed(reason: failureReason), now: now)
        appendReconnectNeededIfPolicyRequiresReconnect(now: now)
        // appendReconnectNeededIfPolicyRequiresReconnect only re-arms the wedge-
        // recovery probe when the failure counters cross the reconnect threshold. An
        // encrypted-fallback success resets consecutiveUpstreamFailureCount to 0, so a
        // marker-only recovery probe whose own re-probe fails leaves the count at 1
        // (< threshold) and would NOT re-arm — stalling the cadence until organic
        // fallback traffic happens to reschedule it. While the wedge marker is still
        // held the primary is still down, so keep the recovery loop running directly
        // (idempotent: the schedule helper no-ops if a probe is already pending, and a
        // genuine recovery clears the marker + cancels the probe before we get here).
        // The encrypted-fallback-COVERED wedge holds no marker (round 11), so re-arm on the
        // carrying-a-FAILED-PROBE signal too — otherwise the covered recapture loop would stall
        // after its own failed re-probe until organic fallback traffic rescheduled it. Use
        // isEncryptedFallbackCarryingWedge (= the gated covering predicate MINUS its rejected==0
        // gate), NOT the gated isEncryptedFallbackCoveringWedge: a single rejected recapture probe
        // flips the gated predicate false (rejected != 0) while the marker is still unstamped, so
        // both gates died and the loop stalled until the 300s routine probe. The carrying predicate
        // keeps the loop alive across the rejection (the streak climbs to the escalation threshold,
        // or the primary recovers) while still REQUIRING a failed smoke-probe context — so a one-off
        // fallback-carried query with no failed probe does not trip recovery. The down-wedge stays
        // marker-only.
        if currentDeviceResolverWedged() || ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: health, now: now) {
            scheduleResolverWedgeRecoveryProbeIfNeeded()
        }
        scheduleProtectionNotificationIfNeeded(now: now)
        #if LAVA_QA_TOOLS
        logQAConnectivityAssessmentIfNeeded(reason: "dns-smoke-probe-failed", now: now)
        #endif

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-failed", details: [
            "reason": reason,
            "failure": health.lastFailureReason ?? "nil",
            "consecutiveSmokeFailures": "\(health.consecutiveDNSSmokeProbeFailureCount)",
            "consecutiveRejectedResponses": "\(health.consecutiveRejectedSmokeResponseCount)"
        ])
    }

    // MARK: - Health reset & network path monitoring

    private func resetHealth() {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.health = TunnelHealthSnapshot(networkKind: self.currentNetworkKind())
            // Lifecycle reset owns the other half of the wedge-marker lifetime
            // (the recovery path owns the rest), so a stale marker can't survive a
            // fresh tunnel session and mis-date a later "recovery".
            self.reconnectNeededSince = nil
            self.reconnectNeededReason = nil
            self.reconnectNeededPeakFailureCount = 0
            self.lastSelfReconnectSuppressionSignature = nil
            self.lastSelfReconnectSuppressionLogAt = nil
            self.lastSelfReconnectPathSkipLogAt = nil
            // The coalesced encrypted-fallback marker is episode-scoped too: a reused
            // provider instance starts a fresh session, so a marker logged <interval ago in
            // the previous session must not suppress (or mis-count) the new session's first
            // carried query.
            self.clearEncryptedFallbackLogThrottle(phase: "context-reset")
            // A reused provider instance (manual stop/start without a process kill) starts a
            // fresh lifecycle that cold-recaptures Device DNS, so a recapture owed by the
            // previous session is moot. Clear it here as well as on recovery, or a later
            // unrelated wedge would be evaluated with the recapture ceiling (Codex P2).
            self.deviceDNSRecaptureRestartPending = false
            // Episode-scoped carried-query failure streak (see
            // resetFailureAndFallbackStateForRecovery) must not survive a fresh tunnel session.
            self.consecutiveCarriedQueryFailureCount = 0
            // A fresh tunnel session re-captures Device DNS at cold start, so any
            // pending masked-handoff capture retry from the previous session is moot.
            self.cancelDeviceDNSCaptureRetry()
            // Likewise drop any wedge-recovery probe (and its fast-ramp attempt counter) owed by
            // the previous session, so a reused provider instance starts the next wedge fresh
            // rather than inheriting a stranded, backed-off cadence.
            self.cancelResolverWedgeRecoveryProbe()
            self.persistHealthIfNeeded(force: true)
        }
    }

    private func startPathMonitor() {
        // A cancelled NWPathMonitor never delivers again, and cleanup cancels the
        // monitor on every stop AND every failed start. Reusing the same object
        // across a same-instance restart (manual stop/start without a process
        // kill, or a setTunnelNetworkSettings-error retry) would leave this handler
        // permanently silent. Create a FRESH monitor each start so the handler can
        // fire again. Cancel the outgoing one first (idempotent — cleanup may have
        // already cancelled it) so we never strand a live monitor on the old object.
        pathMonitor.cancel()
        let monitor = Network.NWPathMonitor()
        pathMonitor = monitor

        // Reset the observed-path state on dnsStateQueue (its owning queue), enqueued
        // BEFORE `start(queue:)` below so it lands ahead of any update the fresh
        // monitor delivers. Without this, a stale "satisfied" could survive the
        // restart: `latestMonitoredPathIsSatisfied` would keep the self-reconnect
        // teardown guard reading true (cancel-into-dead-network), and the stale
        // last-observed path would suppress the fresh monitor's first update as a
        // no-op change, skipping the network-change reset. Optimistic default (true)
        // for latestMonitoredPathIsSatisfied matches "no adverse path info yet"; the
        // last-observed pair goes nil so the first fresh update is treated as initial.
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.latestMonitoredPathIsSatisfied = true
            self.lastObservedPathKind = nil
            self.lastObservedPathIsSatisfied = nil
        }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }

            let update = NetworkPathUpdate(
                kind: Self.tunnelNetworkKind(for: path),
                isSatisfied: path.status == .satisfied,
                statusDescription: Self.pathStatusDescription(path.status)
            )
            // Stamp the freshest delivered path state HERE (this handler already runs
            // on dnsStateQueue), before deferring the heavier handleNetworkPathUpdate to
            // a second turn. The self-reconnect teardown guard reads this rather than
            // `health.networkPathIsSatisfied` (which lands a hop later) so it can't cancel
            // into a path update that's been delivered but not yet applied.
            self.latestMonitoredPathIsSatisfied = update.isSatisfied
            self.dnsStateQueue.async { [weak self] in
                self?.handleNetworkPathUpdate(update)
            }
        }

        monitor.start(queue: dnsStateQueue)
    }

    // Clears recent-failure + device-DNS-fallback state so the next resolver
    // runtime computation and forced reset target the configured DoH/DoT/DoQ
    // resolver, not the fallback (the per-query and smoke-probe paths re-engage
    // fallback if the primary still fails). Shared by the network-change and wake
    // recovery paths so they pick the same runtime. Runs on dnsStateQueue.
    private func resetFailureAndFallbackStateForRecovery() {
        health.lastFailureReason = nil
        health.consecutiveUpstreamFailureCount = 0
        // A fresh network is a fresh primary-health context: drop the smoke-failure
        // streak too, or failures from the previous path would carry over and the first
        // failed settle probe on the new network could cross the reconnect threshold
        // before the new network has actually failed three times.
        health.consecutiveDNSSmokeProbeFailureCount = 0
        deviceDNSFallbackModeActive = false
        consecutiveQueryFallbackSuccessCount = 0
        // The carried-query failure streak is episode-scoped just like the fallback-success
        // evidence above and the smoke streak: a fresh context starts a fresh fallback episode,
        // so drop it too. Otherwise a 1–2 count left from the previous episode would carry over
        // and the first carried failure in the next one could cross the coverage-clear threshold
        // and tear down a freshly-serving encrypted fallback (the single-transient over-escalation
        // the streak gate exists to prevent).
        consecutiveCarriedQueryFailureCount = 0
        // The coalesced encrypted-fallback log marker is episode-scoped exactly like the
        // streaks above: a fresh network/resolver context is a fresh fallback episode, so
        // clear it too, or a marker logged <interval ago on the previous context would
        // suppress the first carried query of the new one.
        clearEncryptedFallbackLogThrottle(phase: "context-reset")
        health.deviceDNSFallbackModeActive = false
        health.lastDeviceDNSFallbackActivatedAt = nil
        clearReconnectNeededActivitySuppression()
        invalidateInFlightSmokeProbes()
    }

    /// Clear the coalesced encrypted-fallback log throttle so the NEXT wedge episode logs
    /// its first carried query immediately. The throttle is episode-scoped, so it must be
    /// cleared wherever a fallback episode ends (primary recovery) or a fresh
    /// resolver/network context begins — otherwise a marker logged <interval ago carries
    /// over and swallows the new episode's first carry.
    private func clearEncryptedFallbackLogThrottle(phase: String = "episode-end") {
        // Flush any carried queries suppressed since the last marker before zeroing, so a
        // short/high-volume wedge that ends before the throttle interval still reports how
        // many queries the fallback saved (the whole point of the count) instead of
        // discarding them. Only emits when there is a pending remainder, so it stays quiet
        // when the throttle is already clear (the common no-op reset).
        //
        // `phase` labels the flush honestly: "episode-end" when the primary genuinely
        // recovered (organic primary query / smoke-probe pass / logConnectivityRecoveredIfWedged),
        // "context-reset" when the episode was instead interrupted by a fresh network/resolver
        // context or a reused-instance session start — the count is still real, but the episode
        // did not "end" via recovery.
        if encryptedFallbackCarriedSinceLastLog > 0 {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-encrypted-fallback", details: [
                "phase": phase,
                "carriedSinceLastLog": "\(encryptedFallbackCarriedSinceLastLog)"
            ])
        }
        lastEncryptedFallbackLogAt = nil
        encryptedFallbackCarriedSinceLastLog = 0
    }

    // Cancels a scheduled fallback-recovery probe and bumps the smoke-probe
    // generation so a probe already in flight can't apply its result after the
    // runtime moved on (the generation guard in completeResolverSmokeProbeResult
    // then discards it). Independent of the fallback decision: wake() invalidates
    // stale probes this way without clearing fallback, while a network change also
    // clears fallback via resetFailureAndFallbackStateForRecovery().
    private func invalidateInFlightSmokeProbes() {
        cancelFallbackRecoverySmokeProbe()
        resolverSmokeProbeGeneration += 1
    }

    private func handleNetworkPathUpdate(_ update: NetworkPathUpdate) {
        let previousKind = lastObservedPathKind
        let previousIsSatisfied = lastObservedPathIsSatisfied
        let isInitialPathUpdate = previousKind == nil && previousIsSatisfied == nil
        let didMeaningfullyChange = previousKind != update.kind || previousIsSatisfied != update.isSatisfied

        lastObservedPathKind = update.kind
        lastObservedPathIsSatisfied = update.isSatisfied
        networkKind = update.kind
        health.networkKind = update.kind
        health.networkPathIsSatisfied = update.isSatisfied

        guard !isInitialPathUpdate, didMeaningfullyChange else {
            markHealthUpdated()
            if isInitialPathUpdate {
                persistHealthIfNeeded(force: true)
            }
            return
        }

        let now = Date()
        health.lastNetworkChangeAt = now
        health.networkChangeCount += 1
        resetFailureAndFallbackStateForRecovery()
        refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "network-path-changed")

        let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
        let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
            identifier: resolverIdentifier,
            reason: "network-path-changed",
            force: true
        )
        resolverBootstrapService.invalidateAll()
        // Bootstrap pre-warm is deferred to the coalesced settle probe below so a
        // flap burst re-resolves once, not per flap (plan item 430).
        markHealthUpdated()
        appendNetworkActivity(
            event: .networkChanged(from: previousKind, to: update.kind, isSatisfied: update.isSatisfied),
            now: now
        )
        #if LAVA_QA_TOOLS
        logQAConnectivityAssessmentIfNeeded(reason: "network-path-changed", now: now)
        #endif
        persistHealthIfNeeded(force: true)
        if !update.isSatisfied {
            // Path is down: drop any pending settle probe so we don't re-handshake
            // into a dead network when the timer fires.
            resolverProbeCoalescer.cancel()
            scheduleProtectionNotificationIfNeeded(now: now)
        }

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-path-changed", details: [
            "previousKind": previousKind?.rawValue ?? "nil",
            "kind": update.kind.rawValue,
            "previousSatisfied": previousIsSatisfied.map { "\($0)" } ?? "nil",
            "isSatisfied": "\(update.isSatisfied)",
            "status": update.statusDescription,
            "pendingResponses": "\(pendingResponses.count)",
            "resolverIdentifier": resolverIdentifier
        ])

        writeServerFailures(for: pendingResponses, reason: "network-path-changed")

        if update.isSatisfied {
            reapplyTunnelNetworkSettings(reason: "network-path-changed", enforceThrottle: true)
            // Coalesce the proactive resolver rebuild (bootstrap pre-warm + smoke
            // probe) so a flap burst re-handshakes once after the path settles,
            // not once per flap (plan item 430). Settings reapply keeps its own
            // ≥1 s throttle above.
            resolverProbeCoalescer.noteUnsettled()
            // dns-recovery optimization C: the immediate capture above (and the
            // +1.5s settle re-capture) can come back empty on a masked handoff,
            // stranding a device-DNS user on the previous network's unreachable
            // resolvers. Re-read on a short cadence until the capture is non-empty
            // so resolution recovers in place instead of waiting on a restart.
            scheduleDeviceDNSCaptureRetryIfNeeded(reason: "network-path-changed")
        } else {
            // Path is down: stop re-reading resolvers into a dead network; the next
            // satisfied update re-arms the retry.
            cancelDeviceDNSCaptureRetry()
        }
    }

    private func reapplyTunnelNetworkSettings(reason: String, enforceThrottle: Bool) {
        let now = Date()
        guard !enforceThrottle || now.timeIntervalSince(lastNetworkSettingsReapplyAt) >= 1 else {
            return
        }

        lastNetworkSettingsReapplyAt = now
        let settingsBundle = makeTunnelNetworkSettingsForCurrentConfiguration()

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-settings-reapply-begin", details: [
            "reason": reason,
            "kind": currentNetworkKind().rawValue,
            "dnsServerAddress": settingsBundle.dnsServerAddress,
            "route": settingsBundle.routeDescription
        ])

        setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel",
                    event: "network-settings-reapply-error",
                    details: Self.errorDebugDetails(error)
                )
            } else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-settings-reapply-success", details: [
                    "reason": reason,
                    "kind": self.currentNetworkKind().rawValue
                ])
            }

            if let error {
                self.recordNetworkSettingsReapplyFailure(error, reason: reason)
            }
        }
    }

    private func recordNetworkSettingsReapplyFailure(_ error: Error, reason: String) {
        let now = Date()
        let failureReason = "\(reason): \(Self.errorSummary(error))"
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.health.lastNetworkSettingsReapplyFailureAt = now
            self.health.lastNetworkSettingsReapplyFailureReason = failureReason
            self.health.networkSettingsReapplyFailureCount += 1
            self.health.lastFailureReason = failureReason
            self.markHealthUpdated()
            self.persistHealthIfNeeded(force: true)
            self.appendNetworkActivity(event: .networkSettingsReapplyFailed(reason: failureReason), now: now)
            self.scheduleProtectionNotificationIfNeeded(now: now)
        }
    }

    // MARK: - Startup shared state & bootstrap snapshot

    private func loadInitialSharedState() -> Bool {
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadInitialSharedState-begin")

        let configuration = loadConfiguration() ?? AppConfiguration()
        let launchFollowsRecentSelfReconnect = Self.launchFollowsRecentSelfReconnect(now: Date())
        setAppConfiguration(configuration)
        // Queue-confine the refresh bookkeeping like setAppConfiguration above and every
        // other access via refreshConfigurationIfNeeded: a prior-lifecycle detached snapshot
        // load can still be inside loadSnapshotInBackground and touch these same markers on
        // dnsStateQueue while this off-queue start runs, so route the writes through the queue
        // (loadInitialSharedState is called from startTunnel, never on dnsStateQueue, so .sync
        // cannot deadlock).
        let configurationModifiedAt = modificationDate(for: configurationURL)
        dnsStateQueue.sync {
            lastConfigurationModifiedAt = configurationModifiedAt
            lastConfigurationRefreshAt = Date()
        }
        // Release any prior-lifecycle resident BEFORE the synchronous bootstrap decode. On a
        // same-instance restart / setTunnelNetworkSettings-failure retry (NOT a fresh process),
        // self.snapshot still holds the previous resident; decoding a fresh up-to-cap (1M-rule)
        // snapshot while a near-budget old one is retained would stack into the 2x-resident peak
        // the reload path explicitly avoids (freedResidentBeforeDecode) and could jetsam the
        // extension. Dropping our reference lets the old tables free before the decode; a lingering
        // prior-lifecycle task keeps its own captured reference, so this is not a use-after-free.
        // readPackets has not started, so nothing serves queries against this transient placeholder.
        snapshotQueue.sync {
            snapshot = FilterSnapshot(blockRules: DomainRuleSet())
            protectionPolicySnapshot = snapshot
            residentSnapshotIdentity = nil
            residentSnapshotHasEnabledFilters = false
            residentFailClosedDueToUnavailableSnapshot = false
        }

        // Compute the bootstrap install off-queue (bootstrapResidentSnapshotFromDisk does disk
        // reads that don't touch snapshotQueue), then publish all resident state in ONE
        // snapshotQueue critical section below.
        let bootstrapSnapshot: any FilterRuntimeSnapshot
        let bootstrapIdentity: PreparedFilterSnapshotIdentity?
        let bootstrapHasEnabledFilters: Bool
        let shouldBeginTransientBootstrapDNSWait: Bool
        if configuration.enabledBlocklistIDs.isEmpty {
            bootstrapSnapshot = configuration.filterSnapshot()
            bootstrapIdentity = nil
            bootstrapHasEnabledFilters = false
            shouldBeginTransientBootstrapDNSWait = false
        } else if let resumed = bootstrapResidentSnapshotFromDisk(configuration: configuration) {
            // Fast-resume from the user's own on-disk artifact so a cold start (notably a
            // self-reconnect that kills + relaunches the process) does NOT serve a block-all
            // FailClosedRuntimeSnapshot window while the async load decodes — the transient
            // false-positives behind LAV-92/93. Wrap + set the identity exactly like the async
            // commit so the immediately-following loadSnapshotInBackground hits the no-op reload
            // gate and SKIPS the redundant multi-MB decode (and its 2x-resident peak).
            bootstrapSnapshot = ResolverAdjustedRuntimeSnapshot(
                base: resumed.snapshot,
                resolver: configuration.resolverPreset
            )
            bootstrapIdentity = resumed.identity
            bootstrapHasEnabledFilters = true
            shouldBeginTransientBootstrapDNSWait = false
        } else {
            // No serviceable in-budget on-disk artifact, or it exceeds the synchronous-decode
            // cap → fail closed (NEVER fail open). The async loadSnapshotInBackground resumes
            // from disk / recompiles and commits the real snapshot. For a RECENT self-reconnect
            // launch, DNS requests in this window are queued briefly below instead of receiving
            // synthetic blocked answers; ordinary cold starts keep the existing immediate
            // fail-closed behavior. Queued DNS is not forwarded while the snapshot is unavailable:
            // it is replayed through the filter only after a current-lifecycle snapshot commits,
            // otherwise it receives SERVFAIL. This bootstrap fail-closed is TRANSIENT — the
            // unavailable marker stays false (below) so it does not suppress a later
            // self-reconnect the way a genuine unavailability does.
            // Security boundary: the self-reconnect wait holds at most 64 DNS requests for <=4s
            // after a recent self-reconnect credit. Timeout, overflow, stale lifecycle, or failed
            // snapshot completion all return SERVFAIL instead of forwarding around the filter.
            bootstrapSnapshot = FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)
            bootstrapIdentity = nil
            bootstrapHasEnabledFilters = false
            shouldBeginTransientBootstrapDNSWait = launchFollowsRecentSelfReconnect
            // Deliberately NOT ledgered at ENTRY (OBS-C2): this window is transient by design —
            // the async loadSnapshotInBackground commits a real snapshot within ~seconds, and the
            // marker stays false below. It is taken on EVERY start for the over-sync-cap /
            // stale-artifact cohort, so an unconditional record here would flood the 50-record
            // ring with routine startups — the exact OBS-1 misleading-true failure the ledger
            // exists to prevent. Coverage instead splits on user visibility (Codex follow-up):
            // a window that actually SERVES a fail-closed query records once from the serve
            // path (recordDiagnostic — durable past the next resetHealth), a quiet window
            // leaves no record, and if the async load also fails closed (over-budget /
            // unbuildable) it records its own transition-gated failClosedEntered.
        }
        // Publish under snapshotQueue. startTunnel can RESTART the same provider instance while a
        // detached snapshot load from the PRIOR lifecycle is still inside loadCompiledSnapshot
        // (stop/cleanup invalidates the reload generation but neither cancels nor awaits that
        // task), and it reads these queue-guarded markers via currentResidentSnapshotIdentity()/
        // currentResidentSnapshotHasEnabledFilters(). So confine the writes to snapshotQueue like
        // every other access (loadInitialSharedState is called from startTunnel, never on
        // snapshotQueue, so .sync cannot deadlock). The bootstrap also FULLY OWNS all three
        // markers, resetting them in EVERY branch: a startTunnel retry after a
        // setTunnelNetworkSettings failure (whose cleanup clears neither) must not let a stale
        // "healthy filtering resident" marker survive into a fail-closed bootstrap and trick the
        // async keep-resident/no-op decisions.
        snapshotQueue.sync {
            snapshot = bootstrapSnapshot
            protectionPolicySnapshot = bootstrapSnapshot
            residentSnapshotIdentity = bootstrapIdentity
            residentSnapshotHasEnabledFilters = bootstrapHasEnabledFilters
            residentFailClosedDueToUnavailableSnapshot = false
        }

        // NetworkExtension can spend most of the bounded wait installing settings before DNS
        // packets can arrive. Clear stale wait state here, but start the timer only after
        // setTunnelNetworkSettings succeeds and the async snapshot load/read loop are about
        // to begin.
        cancelTransientBootstrapDNSWait(reason: "loadInitialSharedState")

        if let diagnosticsURL {
            diagnostics = DiagnosticsPersistence.load(from: diagnosticsURL)
        }

        applyDiagnosticsControlIfNeeded(force: true)
        // A prune performed during load (resetForCurrentDayIfNeeded once the fine-grained
        // retention window has elapsed) sets the store's pending-prune flag but not the
        // persistence controller's dirty flag, so persist when EITHER is set — otherwise an
        // idle start leaves >7-day domain-history events in the app-group JSON until the next
        // DNS event dirties diagnostics, breaking the on-disk retention guarantee.
        let prunedDuringLoad = diagnostics.consumePendingFineGrainedPrunePersist()
        if prunedDuringLoad || diagnosticsPersistence.isDirty {
            persistDiagnosticsIfNeeded(force: true)
        }

        // Startup-side ledger retention sweep (arm/confirm, never single-clock
        // destructive): the on-disk 7-day window must hold even for a device with few
        // incident writes, and tunnel starts are the reliable recurring hook. Like
        // recordIncident, observability-only — nothing reads a result.
        Self.sweepIncidentLedger()

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadInitialSharedState-ready", details: [
            "bootstrapBlockRuleCount": "\(snapshot.blockRuleCount)",
            "bootstrapAllowRuleCount": "\(snapshot.allowRuleCount)"
        ])
        return shouldBeginTransientBootstrapDNSWait
    }

    // MARK: - Transient bootstrap DNS wait

    // The wait's STATE machine lives in TransientBootstrapDNSWait (LavaSecDNS,
    // Phase E2), where the INV-DNS-2 transitions are executable
    // (TransientBootstrapDNSWaitTests). These wrappers keep everything that must
    // stay a provider concern: the query-shape guards, the SERVFAIL writes
    // (writeServerFailures), the replay THROUGH the filter, the device-log events
    // (names/keys unchanged), the INV-QUEUE-1 dual-entry hops, and
    // tunnelLifecycleGeneration ownership.

    private func enqueueTransientBootstrapDNSRequestIfNeeded(
        request: IPv4UDPDNSPacket,
        protocolNumber: Int,
        filterDecision: FilterDecision,
        failClosedReason: String?,
        allowsTransientBootstrapDeferral: Bool
    ) -> Bool {
        guard allowsTransientBootstrapDeferral,
              filterDecision.action == .block,
              filterDecision.reason == .protectionUnavailable,
              failClosedReason == "transient-protection-unavailable"
        else {
            return false
        }

        var serverFailure: PendingDNSResponse?
        var serverFailureReason: String?
        let handledByWait = dnsStateQueue.sync {
            let pending = PendingDNSResponse(
                request: request,
                protocolNumber: protocolNumber,
                maximumAnswerTTL: nil,
                temporaryPauseNormalizedDomain: nil
            )
            switch transientBootstrapDNSWait.enqueue(pending, generation: tunnelLifecycleGeneration) {
            case .rejectExpiredGeneration:
                serverFailure = pending
                serverFailureReason = "transient-bootstrap-dns-wait-timeout"
                return true

            case .notHandled:
                return false

            case .rejectOverflow(let logOnce, let pendingCount):
                serverFailure = pending
                serverFailureReason = "transient-bootstrap-dns-wait-overflow"
                if logOnce {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-overflow", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingCount)"
                    ])
                }
                return true

            case .queued(let isFirst):
                if isFirst {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-queued", details: [
                        "generation": "\(tunnelLifecycleGeneration)"
                    ])
                }
                return true
            }
        }

        if let serverFailure {
            writeServerFailures(for: [serverFailure], reason: serverFailureReason)
        }
        return handledByWait
    }

    private func drainTransientBootstrapDNSWait(reason: String) {
        let drain = { [self] () -> (pendingResponses: [PendingDNSResponse], replayGeneration: UInt64?) in
            switch transientBootstrapDNSWait.drain(currentGeneration: tunnelLifecycleGeneration) {
            case .idle:
                return ([], nil)

            case .staleLifecycle(let pendingResponses):
                if !pendingResponses.isEmpty {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-stale-lifecycle", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                }
                writeServerFailures(
                    for: pendingResponses,
                    reason: "transient-bootstrap-dns-wait-stale-lifecycle"
                )
                return ([], nil)

            case .replay(let pendingResponses, let replayGeneration):
                if !pendingResponses.isEmpty {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-drain", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                }
                return (pendingResponses, replayGeneration)
            }
        }

        let result: (pendingResponses: [PendingDNSResponse], replayGeneration: UInt64?)
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            result = drain()
        } else {
            result = dnsStateQueue.sync(execute: drain)
        }

        replayTransientBootstrapDNSRequests(
            result.pendingResponses,
            expectedLifecycleGeneration: result.replayGeneration
        )
    }

    private func failTransientBootstrapDNSWait(reason: String, expectedGeneration: UInt64? = nil) {
        let fail = { [self] () -> [PendingDNSResponse] in
            // Only the TIMEOUT exit stamps the expired-generation marker (same-
            // lifecycle latecomers keep receiving SERVFAIL); a snapshot-unavailable
            // fail leaves no marker, so latecomers take the normal immediate
            // fail-closed answer. pinned: TransientBootstrapDNSWaitTests
            let isTimeout = reason == "transient-bootstrap-dns-wait-timeout"
            let pendingResponses = transientBootstrapDNSWait.fail(
                expectedGeneration: expectedGeneration,
                marksGenerationExpired: isTimeout
            )
            if !pendingResponses.isEmpty {
                if isTimeout {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-timeout", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                } else {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-failed", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                }
            }
            return pendingResponses
        }

        let pendingResponses: [PendingDNSResponse]
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            pendingResponses = fail()
        } else {
            pendingResponses = dnsStateQueue.sync(execute: fail)
        }

        writeServerFailures(for: pendingResponses, reason: reason)
    }

    private func replayTransientBootstrapDNSRequests(
        _ pendingResponses: [PendingDNSResponse],
        expectedLifecycleGeneration: UInt64?
    ) {
        guard !pendingResponses.isEmpty else {
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }

            guard let expectedLifecycleGeneration,
                  self.isCurrentTunnelLifecycle(expectedLifecycleGeneration)
            else {
                self.writeServerFailures(
                    for: pendingResponses,
                    reason: "transient-bootstrap-dns-wait-stale-lifecycle"
                )
                return
            }

            for pending in pendingResponses {
                self.handleDNSRequest(
                    pending.request,
                    protocolNumber: pending.protocolNumber,
                    allowsTransientBootstrapDeferral: false,
                    expectedLifecycleGeneration: expectedLifecycleGeneration
                )
            }
        }
    }

    private func beginTransientBootstrapDNSWait(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.sync {
                self.beginTransientBootstrapDNSWait(reason: reason)
            }
            return
        }

        let generation = tunnelLifecycleGeneration
        let replacedPendingResponses = transientBootstrapDNSWait.beginWait(generation: generation) { [weak self] expiredGeneration in
            self?.failTransientBootstrapDNSWait(
                reason: "transient-bootstrap-dns-wait-timeout",
                expectedGeneration: expiredGeneration
            )
        }
        writeServerFailures(
            for: replacedPendingResponses,
            reason: "transient-bootstrap-dns-wait-replaced"
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-begin", details: [
            "generation": "\(generation)",
            "reason": reason
        ])
    }

    private func cancelTransientBootstrapDNSWait(reason: String) {
        let cancel = { [self] () -> [PendingDNSResponse] in
            let pendingResponses = transientBootstrapDNSWait.cancelWait()
            if !pendingResponses.isEmpty {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-cancel", details: [
                    "generation": "\(tunnelLifecycleGeneration)",
                    "pendingResponses": "\(pendingResponses.count)",
                    "reason": reason
                ])
            }
            return pendingResponses
        }

        let pendingResponses: [PendingDNSResponse]
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            pendingResponses = cancel()
        } else {
            pendingResponses = dnsStateQueue.sync(execute: cancel)
        }

        writeServerFailures(for: pendingResponses, reason: reason)
    }

    // MARK: - Diagnostics & upstream health recording

    private func recordDiagnostic(
        domain: String,
        decision: FilterDecision,
        failClosedReason: String? = nil
    ) {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.refreshConfigurationIfNeeded()
            // Fail-closed serves stay OUT of user-facing filtering counts and Domain History
            // (record below drops them — #164 honesty rule), but they must leave a durable
            // observability trace: without one, a past fail-closed window is indistinguishable
            // from "no incident" in a field report. Health counters carry no user-count
            // semantics, so trace here — BEFORE the diagnostics-preferences gate, which must
            // not silence it. The reason was captured atomically with the decision under
            // snapshotQueue (a reload can commit a real snapshot before this deferred block
            // runs, so a late marker read could mislabel the window that actually served).
            if decision.reason == .protectionUnavailable {
                let resolvedReason = failClosedReason ?? "transient-protection-unavailable"
                // Force-persist the FIRST trace of a fail-closed window class (and a
                // reason-class change): health writes are debounced 30 s and the app-side
                // sample can skip a provider flush inside that window, so a report filed
                // right after the outage would still read a health file with no trace —
                // the exact gap this trace closes. Subsequent same-window queries ride
                // the debounce (one forced write per window class, not per query).
                let isFirstTraceOfWindowClass = self.health.failClosedServedQueryCount == 0
                    || self.health.lastFailClosedReason != resolvedReason
                self.health.failClosedServedQueryCount += 1
                self.health.lastFailClosedAt = Date()
                self.health.lastFailClosedReason = resolvedReason
                self.markHealthUpdated()
                if isFirstTraceOfWindowClass {
                    self.persistHealthIfNeeded(force: true)
                    // OBS-C2 refinement (Codex): the transient bootstrap window is NOT
                    // ledgered at entry — quiet routine starts must stay silent — but a
                    // window that actually SERVED a query is a user-visible outage whose
                    // only other trace (the health counters above) is session-scoped:
                    // resetHealth() on the next start wipes it, so a late-filed report
                    // after a restart would again read "no incident". Ledger the FIRST
                    // transient serve per window class (at most one record per tunnel
                    // start — never per query, so the 50-record ring cannot flood). The
                    // persistent classes ride their own transition-gated commit-site
                    // records; recording their serves too would double-enter one window.
                    if resolvedReason == "transient-protection-unavailable" {
                        Self.recordIncident(.failClosedEntered, reason: resolvedReason)
                    }
                }
            }
            let configuration = self.currentAppConfiguration()
            guard configuration.keepFilteringCounts || configuration.keepDomainDiagnostics else {
                return
            }

            let rolledOver = self.diagnostics.resetForCurrentDayIfNeeded()
            let recordMutated = self.diagnostics.record(
                domain: domain,
                decision: decision,
                keepFilteringCounts: configuration.keepFilteringCounts,
                keepDomainHistory: configuration.keepDomainDiagnostics
            )
            // Suppressed fail-closed queries leave the store unchanged (record drops them from
            // history + counts), so don't re-dirty/re-persist the same diagnostics file ~every
            // 30s during a fail-closed outage. Still persist when the day rolled over or expired
            // history was pruned — consume the prune flag so it doesn't dangle for the load path.
            let prunePending = self.diagnostics.consumePendingFineGrainedPrunePersist()
            if rolledOver || recordMutated || prunePending {
                self.markDiagnosticsUpdated()
            }
        }
    }

    private func markLocalProtectionUptimeStarted() {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.currentAppConfiguration().keepFilteringCounts else {
                return
            }

            self.diagnostics.startLocalProtectionUptime()
            self.markDiagnosticsUpdated()
            self.persistDiagnosticsIfNeeded(force: true)
        }
    }

    private func refreshConfigurationIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastConfigurationRefreshAt) >= configurationRefreshInterval else {
            return
        }

        lastConfigurationRefreshAt = now
        let modifiedAt = modificationDate(for: configurationURL)
        guard force || modifiedAt != lastConfigurationModifiedAt else {
            return
        }

        if let configuration = loadConfiguration() {
            setAppConfiguration(configuration)
            lastConfigurationModifiedAt = modifiedAt
        }
    }

    // The resolver/network-settings-relevant projection of the configuration.
    // A reload whose projection is unchanged must not reset the DNS runtime or
    // reapply tunnel network settings (which the user sees as a reconnect) —
    // diagnostics toggles and paid status are deliberately excluded.
    private static func resolverNetworkIdentity(_ configuration: AppConfiguration) -> String {
        [
            configuration.resolverPresetID,
            configuration.customResolverAddress ?? "",
            configuration.customResolverSecondaryAddress ?? "",
            configuration.fallbackToDeviceDNS ? "1" : "0",
            // The encrypted Device-DNS fallback resolver is part of the resolver
            // runtime too: changing it (e.g. saving a hostname-based Custom DoH/DoT/DoQ
            // alternative while running) must count as a resolver change so the reload
            // re-warms its bootstrap hostname, rather than leaving it un-warmed until a
            // later packet resets the runtime — by which point Device DNS may be wedged.
            configuration.usesEncryptedDeviceDNSFallback ? "1" : "0",
            configuration.fallbackResolverPresetID,
            configuration.fallbackCustomResolverAddress ?? "",
            configuration.fallbackCustomResolverSecondaryAddress ?? ""
        ].joined(separator: "|")
    }

    private func recordCacheHit() {
        health.cacheHitCount += 1
        markHealthCountersUpdated()
    }

    private func recordCacheMiss() {
        health.cacheMissCount += 1
        markHealthCountersUpdated()
    }

    private func recordCoalescedQuery() {
        health.coalescedQueryCount += 1
        markHealthCountersUpdated()
    }

    private func recordUpstreamResult(_ result: DNSResolutionResult) {
        updateResolverBackoff(from: result.attempts)
        let now = Date()
        let wasDeviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        var activatedDeviceDNSFallback = false
        var recoveredDeviceDNSFallback = false
        let didResolve = result.response != nil

        health.networkKind = currentNetworkKind()
        health.lastResolverAddress = result.successfulResolverAddress ?? result.attempts.last?.address
        health.lastResolverTransport = result.transport
        health.lastUpstreamDurationMilliseconds = result.durationMilliseconds

        if !didResolve {
            consecutiveQueryFallbackSuccessCount = 0
            health.consecutiveSlowUpstreamResponseCount = 0
            health.upstreamFailureCount += 1
            health.consecutiveUpstreamFailureCount += 1
            health.lastFailureReason = result.failureSummary
            health.lastUpstreamFailureAt = now
            // A real client query failed outright — primary AND every fallback leg
            // (incl. the encrypted safety net) failed. Once these are SUSTAINED the
            // encrypted fallback is no longer carrying DNS, so drop its serving
            // timestamp: a stale-but-still-<30s success must not keep the policy at
            // `.usingEncryptedFallback`/`.turnOff` (suppressing the self-reconnect)
            // after DoH/DoT has died. Gated on a streak — NOT the first failure —
            // because in the covered state the primary is wedged, so the policy is
            // re-assessed in THIS call (appendReconnectNeededIfPolicyRequiresReconnect)
            // with a durable smoke-failure count already at the reconnect threshold;
            // clearing on a lone DoH transient would synchronously fire a full
            // self-reconnect — the LAV-80-class restart this path exists to prevent.
            // The policy can't key off `lastUpstreamFailureAt` for this (a covered
            // primary smoke probe bumps that same field), so the streak is tracked here
            // on the forwarding path only; the next carried success resets it (below).
            consecutiveCarriedQueryFailureCount += 1
            if consecutiveCarriedQueryFailureCount >= encryptedFallbackCoverageClearFailureThreshold {
                health.lastEncryptedFallbackSuccessAt = nil
            }
            // NRG-3a: an outright forwarding failure revokes probe-skip evidence — even
            // if a fallback-carried success later resets the failure streak, pre-failure
            // evidence must not let the routine tick skip the probe that re-proves the
            // PRIMARY.
            lastAcceptedPrimaryEvidenceAt = nil
        } else {
            health.upstreamSuccessCount += 1
            health.lastFailureReason = nil
            health.lastUpstreamSuccessAt = now
            health.consecutiveUpstreamFailureCount = 0
            // A carried success means the forwarding path resolves again — reset the
            // carried-failure streak so a fresh outage must re-accumulate from zero
            // before it can tear down encrypted-fallback coverage.
            consecutiveCarriedQueryFailureCount = 0
            if result.usedEncryptedFallback {
                // NRG-3a: a fallback-carried query means the PRIMARY failed to serve it —
                // revoke any pre-failure probe-skip evidence (Codex round 3: coverage can
                // hold the wedge marker and every streak at zero, so nothing else in the
                // skip gate would notice), so the next routine tick probes the primary.
                lastAcceptedPrimaryEvidenceAt = nil
                // The encrypted safety net carried this query — the *primary* device
                // resolver is still wedged. Recording it as a primary recovery would
                // clear `reconnectNeededSince` (the wedge marker `currentDeviceResolverWedged`
                // reads), so the next REFUSED from the still-stale resolver would be
                // treated as authoritative and bypass the fallback — a flap. Keep the
                // lighter recovery probe armed; only a genuine primary success or the
                // primary-only smoke probe clears the wedge.
                //
                // Record that the encrypted fallback is actively serving DNS (a separate
                // signal from `lastPrimaryUpstreamSuccessAt`, which stays untouched so the
                // honesty floor still surfaces the wedged primary). The connectivity policy
                // reads this so a transition-induced primary staleness that the fallback is
                // already covering does not escalate to a user-visible self-reconnect.
                //
                // NB: we deliberately do NOT stamp `reconnectNeededSince` for the covered
                // state. The marker is overloaded — besides arming the in-place recovery
                // probe it also feeds `deviceResolverWedged` into `DNSResolverRuntimePlan`,
                // flipping `treatsResolverRejectionAsFallbackTrigger` (and surviving a path
                // change), which would bypass authoritative SERVFAIL/REFUSED on the wedged
                // and on a freshly-handed-off network. Coverage already works via the
                // per-query fallback (this branch) + the policy's `.usingEncryptedFallback`
                // suppression; the primary re-captures via the existing settle/periodic smoke
                // probes. Faster in-place recovery for the covered state is a separate
                // follow-up that must not reuse this marker.
                health.lastEncryptedFallbackSuccessAt = now
                scheduleResolverWedgeRecoveryProbeIfNeeded()
            } else {
                // The silent recovery banner-clear keys off `lastPrimaryUpstreamSuccessAt`,
                // so record it ONLY for a genuine answer from the *configured primary*
                // resolver — never one a fallback carried while the primary is still
                // down. Two non-encrypted fallback shapes must be excluded here:
                //   * Per-query Device-DNS fallback: `withDeviceDNSFallback` keeps
                //     `usedEncryptedFallback` false (so we land in this branch) but sets
                //     `deviceDNSFallbackSucceeded` — the configured primary failed and the
                //     device resolver answered.
                //   * Device-DNS fallback *mode*: for a non-device configured resolver,
                //     `DNSResolverRuntimePlan.make` makes the effective transport
                //     `.deviceDNS`, so the query resolves via device DNS without setting
                //     `deviceDNSFallbackSucceeded`. That is still fallback traffic, not the
                //     configured primary.
                // A Device-DNS *primary* answering directly is neither (fallback mode can't
                // be active for a device primary), so it still counts. Treating any of the
                // fallback shapes as recovery would silently clear the reconnect banner
                // while DNS still depends on the fallback.
                let resolvedThroughFallbackMode = result.transport == .deviceDNS && wasDeviceDNSFallbackModeActive
                if !result.deviceDNSFallbackSucceeded, !resolvedThroughFallbackMode {
                    // A LEGITIMATE primary answer — NOERROR-with-answers OR an authoritative
                    // negative (NXDOMAIN / NODATA) — proves the configured primary is alive and
                    // serving, so it credits primary recovery. A SERVFAIL/REFUSED or malformed-RR
                    // NOERROR reply does NOT: `completeForward` synthesizes a SERVFAIL for the
                    // client, so crediting it here would let a resolver returning failures between
                    // smoke probes suppress the failed-probe / rejected-response escalation —
                    // `hasUncoveredFailedSmokeProbe` reads `lastPrimaryUpstreamSuccessAt`, and the
                    // reconnect threshold reads `consecutiveDNSSmokeProbeFailureCount` — while
                    // clients keep receiving SERVFAILs (Codex P1). `indicatesServedAnswer` is the
                    // exact `completeForward` bar — not a SERVFAIL/REFUSED rcode AND all RR
                    // sections well-formed — so legitimate NXDOMAIN/NODATA still count as healthy
                    // (no false-reconnect regression) while a SERVFAIL/REFUSED or a malformed
                    // reply, INCLUDING a malformed negative whose authority/additional section is
                    // truncated, does not. `didResolve` guarantees `result.response != nil` here.
                    let primaryServedLegitimateAnswer =
                        DNSResolverSmokeProbe.indicatesServedAnswer(result.response)
                    if primaryServedLegitimateAnswer {
                        health.lastPrimaryUpstreamSuccessAt = now
                    }
                    // NRG-3a: only an answer passing the probe's OWN acceptance check
                    // (NOERROR + answers with WELL-FORMED RRs; the transport already
                    // verified the query identity) counts as probe-equivalent evidence — STAMP.
                    // `didResolve` alone must not — a hijacking resolver's REFUSED/SERVFAIL
                    // reply reaches this branch too (see the LAV-87 NB below). And any reply the
                    // client sees as a SERVFAIL — a SERVFAIL/REFUSED rcode OR a malformed reply
                    // (answer OR authority/additional truncated, which `completeForward` downgrades)
                    // — REVOKES existing evidence (Codex round 2/final): the resolver just proved it
                    // is misbehaving NOW, so pre-failure evidence must not let the next routine tick
                    // skip the very probe that advances the LAV-87 escalation. `indicatesServedAnswer`
                    // is the same `completeForward` bar as the recovery gate above, so a legitimate
                    // well-formed NODATA/NXDOMAIN neither stamps nor revokes.
                    if DNSResolverSmokeProbe.indicatesAcceptedAnswer(result.response) {
                        lastAcceptedPrimaryEvidenceAt = now
                    } else if !primaryServedLegitimateAnswer {
                        // `primaryServedLegitimateAnswer` (bound above) is
                        // `indicatesServedAnswer(result.response)` — reuse it instead of
                        // recomputing the same full-RR walk on the same immutable response.
                        lastAcceptedPrimaryEvidenceAt = nil
                    }
                    // A genuine primary answer also proves the primary's health, so it
                    // clears the consecutive smoke-failure streak — otherwise isolated
                    // probe failures separated by healthy primary traffic would
                    // accumulate to the reconnect threshold and falsely prompt a
                    // reconnect. Gated by the same primary-only condition so a
                    // fallback-carried success never resets it — AND by
                    // `primaryServedLegitimateAnswer` so a SERVFAIL/REFUSED/malformed reply
                    // (which is NOT the primary serving) can't reset the escalation streak.
                    if primaryServedLegitimateAnswer {
                        health.consecutiveDNSSmokeProbeFailureCount = 0
                    }
                    // The encrypted fallback did NOT carry THIS query (we're in the
                    // !usedEncryptedFallback branch), so it is not covering — clear its serving
                    // timestamp on ANY non-fallback primary reply, INCLUDING a failing one
                    // (Codex P1). `isUsingEncryptedFallback` has no freshness ceiling, so a stale
                    // fallback-success from an earlier carried query would otherwise make a later
                    // timeout/receive-failed smoke probe look covered and suppress the reconnect.
                    // Deliberately NOT gated on `primaryServedLegitimateAnswer` (unlike the
                    // primary-success stamp / streak clear above): those credit primary RECOVERY,
                    // which a SERVFAIL is not; this only records that the fallback isn't the
                    // active carrier, which holds regardless of the primary's rcode.
                    health.lastEncryptedFallbackSuccessAt = nil
                    // NB (LAV-87): the rejected-response streak is deliberately NOT cleared
                    // here. `didResolve` is `response != nil`, so a hijacking resolver's
                    // REFUSED/SERVFAIL reply to an ordinary query reaches this "primary
                    // success" branch too (pre-wedge, ResolverOrchestrator passes rejections
                    // through). Clearing it would let organic rejected replies reset the
                    // streak between smoke probes so it never reaches the threshold. Only an
                    // accepted primary *smoke* probe (known-good domain) or a resolver change
                    // clears it; a genuine organic recovery is still covered by the
                    // `lastPrimaryUpstreamSuccessAt` guard in `hasUncoveredFailedSmokeProbe`.
                }
                // Record recovery before clearing the wedge state (organic-query path).
                logConnectivityRecoveredIfWedged(transport: result.transport, verifiedBy: "forwarding", now: now)
                clearReconnectNeededActivitySuppression()
            }
            if let durationMilliseconds = result.durationMilliseconds,
               durationMilliseconds >= Self.slowUpstreamResponseThresholdMilliseconds {
                health.slowUpstreamResponseCount += 1
                health.consecutiveSlowUpstreamResponseCount += 1
                health.lastSlowUpstreamResponseAt = now
            } else {
                health.consecutiveSlowUpstreamResponseCount = 0
            }
            if !result.deviceDNSFallbackSucceeded, result.transport != .deviceDNS {
                consecutiveQueryFallbackSuccessCount = 0
            }
            if wasDeviceDNSFallbackModeActive,
               result.transport != .deviceDNS,
               !result.deviceDNSFallbackSucceeded {
                deviceDNSFallbackModeActive = false
                health.deviceDNSFallbackModeActive = false
                health.lastDeviceDNSFallbackActivatedAt = nil
                consecutiveQueryFallbackSuccessCount = 0
                cancelFallbackRecoverySmokeProbe()
                recoveredDeviceDNSFallback = true
            }
        }

        if result.udpTruncated {
            health.udpTruncatedResponseCount += 1
        }

        if result.tcpFallbackAttempted {
            health.tcpFallbackAttemptCount += 1
        }

        if result.tcpFallbackSucceeded {
            health.tcpFallbackSuccessCount += 1
        }

        if result.deviceDNSFallbackAttempted {
            health.deviceDNSFallbackAttemptCount += 1
        }

        if result.deviceDNSFallbackSucceeded {
            // NRG-3a: the Device-DNS LEG carried this query because the configured
            // primary failed it — revoke probe-skip evidence even below the fallback-
            // mode activation threshold (Codex round 4: mode stays inactive and every
            // streak stays clear down here, so if the routine tick lands before the
            // ~30s recovery probe, pre-failure evidence would skip the very probe
            // that counts toward activation).
            lastAcceptedPrimaryEvidenceAt = nil
            health.deviceDNSFallbackSuccessCount += 1
            consecutiveQueryFallbackSuccessCount = DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
                currentCount: consecutiveQueryFallbackSuccessCount,
                primaryResolverWasAttempted: result.hasFallbackActivationEvidence
            )
            if !deviceDNSFallbackModeActive {
                if DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                    consecutiveQueryFallbackSuccesses: consecutiveQueryFallbackSuccessCount
                ) {
                    deviceDNSFallbackModeActive = true
                    health.deviceDNSFallbackModeActive = true
                    health.lastDeviceDNSFallbackActivatedAt = now
                    health.deviceDNSFallbackActivationCount += 1
                    activatedDeviceDNSFallback = true
                }
            } else {
                health.deviceDNSFallbackModeActive = true
            }
        }

        if result.deviceDNSUnavailable {
            health.deviceDNSUnavailableCount += 1
        }

        for attempt in result.attempts {
            health.resolverAttemptCounts[attempt.address, default: 0] += 1

            switch attempt.outcome {
            case .success:
                health.resolverSuccessCounts[attempt.address, default: 0] += 1
                if attempt.transport == .dnsOverHTTPS, let negotiatedDoHProtocol = attempt.negotiatedDoHProtocol {
                    health.lastDoHHTTPVersion = negotiatedDoHProtocol
                }
            case .timeout:
                health.upstreamTimeoutCount += 1
                health.resolverFailureCounts[attempt.address, default: 0] += 1
            case .httpStatusFailure:
                health.dohHTTPFailureCount += 1
                health.resolverFailureCounts[attempt.address, default: 0] += 1
            case .backedOff,
                 .sendFailed,
                 .receiveFailed,
                 .invalidAddress,
                 .unsupported,
                 .socketUnavailable,
                 .mismatchedResponse,
                 .deviceDNSUnavailable:
                health.resolverFailureCounts[attempt.address, default: 0] += 1
            }
        }

        health.deviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        markHealthUpdated()
        if activatedDeviceDNSFallback {
            appendNetworkActivity(event: .deviceDNSFallbackActivated(reason: "query-fallback"), now: now)
            scheduleFallbackRecoverySmokeProbeIfNeeded()
        } else if recoveredDeviceDNSFallback {
            appendNetworkActivity(event: .deviceDNSFallbackRecovered, now: now)
        } else if result.deviceDNSFallbackSucceeded {
            scheduleFallbackRecoverySmokeProbeIfNeeded()
        }

        if !didResolve {
            appendReconnectNeededIfPolicyRequiresReconnect(now: now)
        }

        if result.usedEncryptedFallback {
            // The Device-DNS primary was wedged and the encrypted (Mullvad DoH)
            // fallback carried this query — un-gated + privacy-safe (resolver
            // endpoint, never a queried domain), so field exports show the safety
            // net engaging and how often it saves a wedge. Coalesced: log the first
            // carried query of an episode immediately, then throttle to one marker per
            // `encryptedFallbackLogThrottleInterval` carrying `carriedSinceLastLog`, so a
            // sustained wedge does not flood the debug ring. The throttle is reset when the
            // episode ends — either the primary serves a query (the `else` below) or the
            // wedge recovers via the smoke probe (`logConnectivityRecoveredIfWedged`).
            encryptedFallbackCarriedSinceLastLog += 1
            let dueForFallbackLog = lastEncryptedFallbackLogAt.map {
                now.timeIntervalSince($0) >= encryptedFallbackLogThrottleInterval
            } ?? true
            if dueForFallbackLog {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-encrypted-fallback", details: [
                    "transport": result.transport.rawValue,
                    "resolver": result.successfulResolverAddress ?? "nil",
                    "carriedSinceLastLog": "\(encryptedFallbackCarriedSinceLastLog)"
                ])
                lastEncryptedFallbackLogAt = now
                encryptedFallbackCarriedSinceLastLog = 0
            }
        } else if didResolve && !result.deviceDNSFallbackSucceeded {
            // The PRIMARY carried this query — not the Device-DNS fallback, which is a distinct
            // fallback path (see usedEncryptedFallback vs deviceDNSFallbackSucceeded) and not a
            // primary recovery — so the encrypted-fallback episode is genuinely over. Clear the
            // throttle so the next wedge logs its first carried query. (Covers a brief blip that
            // never set the wedge marker, so `logConnectivityRecoveredIfWedged` would not fire.)
            // Excluding the Device-DNS fallback keeps a mixed-fallback interleave from
            // prematurely resetting the encrypted-fallback throttle.
            clearEncryptedFallbackLogThrottle()
        }
        #if LAVA_QA_TOOLS
        logQAConnectivityAssessmentIfNeeded(
            reason: didResolve ? "upstream-success" : "upstream-failure",
            now: now
        )
        #endif

        if activatedDeviceDNSFallback || didResolve {
            scheduleProtectionNotificationIfNeeded(now: now)
        }
    }

    private func updateResolverBackoff(from attempts: [ResolverAttempt], now: Date = Date()) {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.record(
                attempts.map {
                    ResolverBackoffPolicy.Attempt(
                        address: $0.address,
                        outcome: ResolverBackoffPolicy.AttemptOutcome($0.outcome)
                    )
                },
                now: now
            )
        }
    }

    private func markHealthUpdated() {
        health.updatedAt = Date()
        health.networkKind = currentNetworkKind()
        signalAppIfConnectivityStateChanged()
        healthPersistence.markDirty()
    }

    /// The per-query counter bumps (`recordCacheHit` / `recordCacheMiss` /
    /// `recordCoalescedQuery`) update only stats fields the connectivity
    /// assessment never reads (`cacheHitCount` / `cacheMissCount` /
    /// `coalescedQueryCount`), so they must NOT re-run the full
    /// `ProtectionConnectivityPolicy` cascade. Doing so on every served query
    /// was pure steady-state CPU work that always produced the same severity
    /// (the Darwin nudge is deduped by key anyway, so the post was already a
    /// no-op there). Connectivity-relevant mutations keep going through
    /// `markHealthUpdated`, which still reassesses and signals. dnsStateQueue-confined.
    private func markHealthCountersUpdated() {
        health.updatedAt = Date()
        health.networkKind = currentNetworkKind()
        healthPersistence.markDirty()
    }

    /// Posts the tunnel-health Darwin nudge when the connectivity-relevant state
    /// (the assessment that drives the Dynamic Island's reconnecting / network
    /// lost / needs-reconnect glyphs) changes. Deduped so routine health churn
    /// that does not change the derived state stays quiet. dnsStateQueue-confined,
    /// like the `health` it reads (UR-6).
    private func signalAppIfConnectivityStateChanged(now: Date = Date()) {
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        let key = "\(assessment.severity.diagnosticLabel)|\(String(describing: assessment.primaryAction))"
        guard key != lastSignaledConnectivityKey else {
            return
        }

        lastSignaledConnectivityKey = key
        connectivitySignalNotifier.postNotification(named: TunnelHealthSignal.darwinNotificationName)
    }

    private func persistHealthIfNeeded(force: Bool = false) {
        healthPersistence.flush(force: force)
    }

    // MARK: - Protection notifications & network activity log

    private func scheduleProtectionNotificationIfNeeded(now: Date = Date()) {
        let defaults = LavaSecAppGroup.sharedDefaults
        LavaSecAppGroup.migrateProtectionNotificationStateIfNeeded(defaults)
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        let history = protectionNotificationHistory(defaults: defaults)
        let resolvedNotificationIdentifiers = ProtectionConnectivityNotificationPolicy
            .resolvedProblemNotificationIdentifiers(
                for: assessment,
                health: health,
                history: history,
                now: now
            )
        let notificationCenter = UNUserNotificationCenter.current()
        if !resolvedNotificationIdentifiers.isEmpty {
            Self.clearResolvedProblemNotifications(
                resolvedNotificationIdentifiers,
                cooldownAnchor: ProtectionConnectivityNotificationPolicy.deliveryCooldownAnchorAfterClear(
                    for: assessment,
                    history: history,
                    now: now
                ),
                defaults: defaults,
                notificationCenter: notificationCenter
            )
        } else if assessment.severity == .usingEncryptedFallback {
            // Coverage is active with NO problem banner outstanding to clear. Still lift the
            // exact-id duplicate guard so a later lapse back to a real problem with the same
            // truncated-second event id isn't suppressed by notification(for:)'s id guard
            // (the outstanding-problem case clears it via clearResolvedProblemNotifications).
            defaults.removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)
        }

        // Customization → Notifications: the "Connection updates" toggle gates only the CREATION of new
        // reconnect banners — placed AFTER the resolved-banner cleanup above so disabling mid-problem still
        // clears a stale banner when the network recovers (Codex P2).
        guard LavaNotificationPreferences.isEnabled(.connectivity, in: defaults) else { return }

        // Use the pre-clear `history`: clearResolvedProblemNotifications above wipes
        // the unresolved-problem markers from defaults, but notification(for:)'s
        // escalation / exact-id duplicate-guard logic needs to see the outstanding
        // marker. Re-reading here would always miss it.
        guard let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: assessment,
            health: health,
            history: history,
            now: now,
            languageCode: LavaNotificationLanguage.pinnedCode(in: defaults)
        ) else {
            return
        }

        notificationCenter.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            case .notDetermined, .denied:
                return
            @unknown default:
                return
            }

            Self.recordProtectionNotificationDelivery(notification)

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.interruptionLevel = .passive
            content.userInfo = [
                LavaSecAppGroup.protectionNotificationRouteUserInfoKey:
                    LavaSecAppGroup.protectionNotificationGuardRouteValue,
                LavaSecAppGroup.protectionNotificationKindUserInfoKey: notification.kind.rawValue,
                LavaSecAppGroup.protectionNotificationIDUserInfoKey: notification.identifier
            ]

            let request = UNNotificationRequest(
                identifier: LavaSecAppGroup.protectionNotificationRequestIdentifier(
                    for: notification.identifier
                ),
                content: content,
                trigger: nil
            )
            notificationCenter.add(request) { error in
                guard error == nil else {
                    return
                }

                Self.removeSupersededProtectionNotifications(
                    for: notification,
                    notificationCenter: notificationCenter
                )
            }
        }
    }

    private func protectionNotificationHistory(
        defaults: UserDefaults
    ) -> ProtectionConnectivityNotificationHistory {
        let unresolvedProblemKind = defaults.string(
            forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey
        ).flatMap(ProtectionConnectivityNotificationKind.init(rawValue:))

        return ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: defaults.string(
                forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey
            ),
            lastDeliveredAt: defaults.object(
                forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey
            ) as? Date,
            unresolvedProblemNotificationID: defaults.string(
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey
            ),
            unresolvedProblemKind: unresolvedProblemKind
        )
    }

    private static func recordProtectionNotificationDelivery(_ notification: ProtectionConnectivityNotification) {
        let defaults = LavaSecAppGroup.sharedDefaults

        defaults.set(
            notification.identifier,
            forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey
        )

        // Only actionable problem banners are delivered now, and they advance the
        // throttle clock: the 600s minimum-problem-interval keys off this
        // timestamp. (A self-recovery clears the outstanding markers silently via
        // the resolved-problem clear, so there's no delivered acknowledgement here.)
        if notification.kind.isProblem {
            defaults.set(Date(), forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey)
            defaults.set(
                notification.identifier,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey
            )
            defaults.set(
                notification.kind.rawValue,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey
            )
        }
    }

    private static func removeSupersededProtectionNotifications(
        for notification: ProtectionConnectivityNotification,
        notificationCenter: UNUserNotificationCenter
    ) {
        let requestIdentifiers = notification.supersededNotificationIdentifiers.map {
            LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0)
        }
        guard !requestIdentifiers.isEmpty else {
            return
        }

        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }

    private static func clearResolvedProblemNotifications(
        _ identifiers: [String],
        cooldownAnchor: Date?,
        defaults: UserDefaults,
        notificationCenter: UNUserNotificationCenter
    ) {
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey)
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey)
        // Back-date the delivery cooldown ONLY for the encrypted-fallback silent supersede
        // (cooldownAnchor non-nil); a real `.healthy` recovery passes nil and keeps its
        // anti-flap cooldown intact.
        if let cooldownAnchor {
            defaults.set(cooldownAnchor, forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey)
            // Also lift the exact-id duplicate guard. The silent supersede removed the
            // reconnect banner from the OS, so if coverage lapses before a new smoke probe
            // shifts the event id, the recurring `reconnect-needed:<event>` candidate must be
            // free to re-post. A stale id here would let `notification(for:)`'s duplicate
            // guard suppress the actionable banner until some later probe changes the id,
            // defeating the back-dated cooldown. The cooldown anchor stays the sole gate, so
            // a flapping wedge is still bounded to one banner per `reFlapGraceInterval`.
            defaults.removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)
        }

        let requestIdentifiers = identifiers.map {
            LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0)
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }

    private func appendNetworkActivity(
        event: NetworkActivityEvent,
        now: Date = Date()
    ) {
        let configuration = currentAppConfiguration()
        guard configuration.keepNetworkActivity else {
            return
        }

        guard let networkActivityLogURL else {
            return
        }

        let assessment = ProtectionConnectivityPolicy.assessment(isConnected: true, health: health, now: now)
        let entry = NetworkActivityLogEntry(
            timestamp: now,
            event: event,
            lavaState: LavaStateSnapshot(
                protectionStatus: "Connected",
                connectivityStatus: assessment.severity.diagnosticLabel,
                networkKind: health.networkKind,
                networkPathIsSatisfied: health.networkPathIsSatisfied,
                resolverDisplayName: configuration.resolverPreset.displayName,
                resolverTransport: health.lastResolverTransport,
                fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
                deviceDNSFallbackActive: deviceDNSFallbackModeActive
            )
        )
        // The entry is built synchronously on the calling (DNS-serving) queue from
        // queue-confined state, but the disk write hops off it (CON-1): a serial IO queue
        // + non-blocking bounded lock means a suspended app holding the app-group lock can
        // never wedge DNS. Serial ⇒ entries land in submission (timestamp) order. This is the
        // network-activity queue, kept separate from the incident ledger's (Codex #200 P2).
        let logURL = networkActivityLogURL
        Self.networkActivityLogIOQueue.async {
            // tryAppend = non-blocking + drop-on-contention (tunnel only). The app uses the
            // blocking `append` so its user-action writes are never dropped (CON-1 P2).
            NetworkActivityLogPersistence.tryAppend(entry, to: logURL)
        }
    }

    private func appendReconnectNeededIfPolicyRequiresReconnect(now: Date) {
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        guard assessment.primaryAction == .reconnect else {
            return
        }

        // Stamp the wedge start once, on entry — the basis for the recovery
        // duration (not lastUpstreamFailureAt, which refreshes on every failed
        // query and would shrink a multi-minute outage to "since the last lookup").
        // Capture the reason here too, so a recovery logged after a network-change
        // reset (which clears the notify-throttle reason) still reports it.
        if reconnectNeededSince == nil {
            reconnectNeededSince = now
            reconnectNeededReason = health.lastFailureReason ?? "upstream-failed"
            Self.recordIncident(.wedgeDetected, reason: reconnectNeededReason, now: now)
        }
        // Track the worst failure depth across the wedge (survives the
        // network-change reset that zeroes the live counter).
        reconnectNeededPeakFailureCount = max(reconnectNeededPeakFailureCount, health.consecutiveUpstreamFailureCount)

        let shouldNotify: Bool
        if let lastReconnectNeededActivityAt {
            shouldNotify = now.timeIntervalSince(lastReconnectNeededActivityAt) >= reconnectNeededActivityReminderInterval
        } else {
            shouldNotify = true
        }

        if shouldNotify {
            let reason = health.lastFailureReason ?? "upstream-failed"
            appendNetworkActivity(event: .reconnectNeeded(reason: reason), now: now)
            lastReconnectNeededActivityAt = now
        }

        // When the wedge persists, escalate from notifying to actually restarting
        // the tunnel — startup re-captures Device DNS for the current network,
        // which an in-place recovery can't while the tunnel is active.
        selfReconnectIfPolicyAllows(assessment: assessment, now: now)

        // Always arm the lighter in-place recovery too: self-reconnect is
        // rate-limited and gated on confirmed Connect-On-Demand, so it can be
        // suppressed exactly when the user is stuck. The wedge-recovery re-probe
        // resets the backoff penalty box and re-tests without a process restart,
        // so DNS self-heals on a same-network wedge instead of waiting on a manual
        // toggle. No-op while one is already pending or once DNS recovers.
        scheduleResolverWedgeRecoveryProbeIfNeeded()
    }

    // Restart the tunnel to recover wedged DNS, rate-limited so a network that
    // simply can't resolve can't drive a restart loop. The restart kills this
    // process, so attempt history is persisted (in the app group) and read back on
    // the next launch for the cross-restart backoff. Only fires when protection is
    // enabled — Connect-On-Demand is what brings the tunnel back after the cancel.
    // MARK: - Self-reconnect & guarded teardown

    private func selfReconnectIfPolicyAllows(assessment: ProtectionConnectivityAssessment, now: Date) {
        guard !hasRequestedSelfReconnect else {
            return
        }

        // A fail-closed caused by an unavailable/unbuildable snapshot blocks all DNS, so
        // the smoke probe always fails — but restarting the extension cannot rebuild a
        // snapshot the config can't compile. Restarting would only flicker the VPN (the
        // exact loop that bricked Guard after a stale-pinned-hash refresh). Stay stable
        // fail-closed; recovery comes from the app re-publishing a buildable snapshot, not
        // a restart. (Runs on dnsStateQueue; the read takes snapshotQueue, a leaf lock that
        // never reaches back to dnsStateQueue, so the cross-queue read can't deadlock.)
        guard !isResidentFailClosedDueToUnavailableSnapshot() else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-suppressed-snapshot-unavailable", details: [
                "reason": health.lastFailureReason ?? "snapshot-unavailable"
            ])
            return
        }

        let rawAttempts = Self.loadSelfReconnectAttemptTimes()
        // Normalize and self-heal the persisted store before deciding. prunedAttemptTimes
        // clamps future-dated entries (from a backward clock jump) to `now`; if we only
        // persisted on a reconnect, a future-dated entry would survive in defaults and
        // re-clamp to the advancing `now` on every evaluation, throttling self-reconnect
        // until wall time caught up to the bad timestamp. Persisting the normalized list
        // now rewrites the bad entry once so it ages out of the window normally.
        let attempts = TunnelSelfReconnectPolicy.prunedAttemptTimes(rawAttempts, now: now)
        if attempts != rawAttempts {
            Self.saveSelfReconnectAttemptTimes(attempts)
        }
        // When a no-fallback device-DNS recapture restart was throttled, the recovery
        // retry re-enters HERE via the wedge-recovery probe. Carry the recapture reason
        // so its higher ceiling (3) still applies — otherwise the default `.wedge` cap
        // (2) would discard the recapture cap and suppress the intended third recapture
        // restart until the 600s window ages out (Codex P1).
        let restartReason: TunnelSelfReconnectPolicy.RestartReason =
            deviceDNSRecaptureRestartPending ? .deviceDNSRecapture : .wedge
        let decision = TunnelSelfReconnectPolicy.decision(
            assessment: assessment,
            protectionEnabled: currentAppConfiguration().protectionEnabled,
            onDemandEnabled: Self.isOnDemandConfirmedEnabled(),
            recentReconnectTimes: attempts,
            reason: restartReason,
            now: now
        )
        guard decision == .reconnect else {
            // Surface *why* a wedge did not trigger a restart — the most common
            // "it said reconnect needed but never recovered" case. Un-gated and
            // privacy-safe (no queried domain is recorded), so Release/TestFlight
            // feedback reports carry the suppression reason. The lighter
            // wedge-recovery re-probe still runs regardless of this decision.
            //
            // A persistent wedge calls this on every failed query/tick, so dedup the
            // line: log only when the suppression signature changes or the cooldown
            // elapses, to keep one wedge from flooding (and evicting) the capped log.
            let reason = health.lastFailureReason ?? "dns-wedged"
            let signature = "\(decision)|\(restartReason)|\(reason)|\(currentAppConfiguration().protectionEnabled)|\(Self.isOnDemandConfirmedEnabled())"
            let changed = signature != lastSelfReconnectSuppressionSignature
            let cooldownElapsed = lastSelfReconnectSuppressionLogAt.map {
                now.timeIntervalSince($0) >= Self.selfReconnectSuppressionLogInterval
            } ?? true
            if changed || cooldownElapsed {
                lastSelfReconnectSuppressionSignature = signature
                lastSelfReconnectSuppressionLogAt = now
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-suppressed", details: [
                    "decision": String(describing: decision),
                    "restartReason": "\(restartReason)",
                    "protectionEnabled": "\(currentAppConfiguration().protectionEnabled)",
                    "onDemandConfirmed": "\(Self.isOnDemandConfirmedEnabled())",
                    "attemptsInWindow": "\(attempts.count)",
                    "reason": reason
                ])
            }
            return
        }

        lastSelfReconnectSuppressionSignature = nil
        lastSelfReconnectSuppressionLogAt = nil
        hasRequestedSelfReconnect = true

        performGuardedSelfReconnectTeardown(reason: restartReason, attempts: attempts, now: now)
    }

    // Track 4 — the gated cold-restart that re-captures the new network's device
    // resolver after a no-fallback resolver-changing handoff. Phase 0 proved a cold
    // `startTunnel` is the ONLY thing that re-captures it (iOS masks the real resolver
    // in-place while the tunnel owns system DNS), so a controlled, capped restart IS the
    // legitimate recapture. Called ONLY from the capture-retry exhaustion branch when
    // device DNS is required AND there is no encrypted fallback to carry the handoff (the
    // fallback case is Track 3 / Option-A suppression and must NOT restart for benign
    // staleness). Mirrors the wedge path's front-half guards (latch, snapshot anti-brick,
    // attempt load/self-heal, on-demand-confirmed via decision()) but with the
    // `.deviceDNSRecapture` ceiling and the shared teardown. The `.needsReconnect`
    // severity gate inside decision() stays: in active use organic-query failures drive it
    // there within seconds, so the restart is prompt, while a stale resolver that still
    // *works* (capture merely masked, queries succeeding) never reaches it and is left
    // alone. On a throttled/declined decision it arms the in-place wedge-recovery probe so
    // recovery still happens eventually without a restart (the always-eventually-retry
    // backstop the exhaustion branch does not otherwise arm); on a throttle it also marks
    // `deviceDNSRecaptureRestartPending` so the probe's recovery retry — which re-enters the
    // wedge path — keeps the recapture ceiling instead of falling back to the wedge cap.
    private func promptDeviceDNSRecaptureRestartIfPolicyAllows(now: Date) {
        guard !hasRequestedSelfReconnect else {
            return
        }
        guard !isResidentFailClosedDueToUnavailableSnapshot() else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-suppressed-snapshot-unavailable", details: [
                "reason": health.lastFailureReason ?? "snapshot-unavailable"
            ])
            return
        }

        let rawAttempts = Self.loadSelfReconnectAttemptTimes()
        let attempts = TunnelSelfReconnectPolicy.prunedAttemptTimes(rawAttempts, now: now)
        if attempts != rawAttempts {
            Self.saveSelfReconnectAttemptTimes(attempts)
        }
        let assessment = ProtectionConnectivityPolicy.assessment(isConnected: true, health: health, now: now)
        let decision = TunnelSelfReconnectPolicy.decision(
            assessment: assessment,
            protectionEnabled: currentAppConfiguration().protectionEnabled,
            onDemandEnabled: Self.isOnDemandConfirmedEnabled(),
            recentReconnectTimes: attempts,
            reason: .deviceDNSRecapture,
            now: now
        )
        guard decision == .reconnect else {
            let reason = health.lastFailureReason ?? "device-dns-recapture"
            let signature = "recapture|\(decision)|\(reason)|\(Self.isOnDemandConfirmedEnabled())"
            let changed = signature != lastSelfReconnectSuppressionSignature
            let cooldownElapsed = lastSelfReconnectSuppressionLogAt.map {
                now.timeIntervalSince($0) >= Self.selfReconnectSuppressionLogInterval
            } ?? true
            if changed || cooldownElapsed {
                lastSelfReconnectSuppressionSignature = signature
                lastSelfReconnectSuppressionLogAt = now
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-suppressed", details: [
                    "decision": String(describing: decision),
                    "restartReason": "deviceDNSRecapture",
                    "onDemandConfirmed": "\(Self.isOnDemandConfirmedEnabled())",
                    "attemptsInWindow": "\(attempts.count)",
                    "reason": reason
                ])
            }
            // Reaching this no-fallback exhaustion path means the device resolver could NOT
            // be recaptured, so a recapture restart is owed regardless of the decision —
            // `.throttled` (rate-limited) AND `.noAction` (severity not yet `.needsReconnect`
            // because traffic is idle/low, or on-demand not yet confirmed; `.noAction` is NOT
            // exclusively "DNS still works"). Mark it pending so the recovery retry that
            // re-enters selfReconnectIfPolicyAllows carries the recapture ceiling instead of
            // the lower wedge cap (Codex P1/P2). It clears the moment the resolver is confirmed
            // recovered (a smoke-probe success routes through clearReconnectNeededActivitySuppression),
            // so a genuinely-healthy stale resolver does not leave it stuck on.
            deviceDNSRecaptureRestartPending = true
            // Always-eventually-retry backstop: the in-place wedge-recovery probe re-tests
            // without a restart and self-heals once the resolver un-masks. For an uncovered
            // down-wedge it now re-tests on the escalating fast cadence (first ~2s), not a flat 30s.
            scheduleResolverWedgeRecoveryProbeIfNeeded()
            return
        }

        lastSelfReconnectSuppressionSignature = nil
        lastSelfReconnectSuppressionLogAt = nil
        hasRequestedSelfReconnect = true
        performGuardedSelfReconnectTeardown(reason: .deviceDNSRecapture, attempts: attempts, now: now)
    }

    // The guarded teardown half of a self-reconnect, shared by the wedge escalation
    // (selfReconnectIfPolicyAllows — `.wedge`, or `.deviceDNSRecapture` when a throttled
    // recapture restart is still pending) and the Track-4 recapture restart
    // (promptDeviceDNSRecaptureRestartIfPolicyAllows, reason `.deviceDNSRecapture`). The
    // caller has already set `hasRequestedSelfReconnect` and decided a restart is warranted;
    // this re-validates on a fresh dnsStateQueue turn and issues the cancel.
    private func performGuardedSelfReconnectTeardown(
        reason: TunnelSelfReconnectPolicy.RestartReason,
        attempts: [Date],
        now: Date
    ) {
        // The decision and every `health` read above ran on dnsStateQueue, but the network
        // path can change before the teardown actually lands. A handoff that is still
        // settling flips the path to unsatisfied; cancelling then tears the tunnel down INTO
        // a dead network, where Connect-On-Demand has nothing to restart into — lengthening
        // the user-visible OFF window (field-confirmed 2026-06-22).
        //
        // Re-validate on a *fresh* dnsStateQueue turn, and gate on the freshest delivered
        // path state — `latestMonitoredPathIsSatisfied`, which the pathUpdateHandler stamps
        // synchronously. We deliberately do NOT rely on `health.networkPathIsSatisfied`
        // alone: handleNetworkPathUpdate applies that one via a SECOND deferred hop, so a
        // delivered-but-not-yet-applied path update would leave the cached flag
        // stale-satisfied and let the cancel through (the race Codex flagged). Require BOTH.
        // On an unsatisfied path, release the latch and re-arm the lighter wedge-recovery
        // probe instead of cancelling blind — and do NOT burn a cap attempt for a teardown
        // that never ran (the cap-strand that otherwise compounds into a longer off).
        dnsStateQueue.async { [weak self] in
            guard let self, self.hasRequestedSelfReconnect else {
                return
            }
            // A queued smoke-probe or organic-query success can run on this queue between
            // the decision and this fresh turn, clearing the wedge WITHOUT clearing this
            // latch. Re-RUN THE FULL self-reconnect policy against fresh `health` (NOT just
            // `primaryAction == .reconnect`: a wedge cleared to `.dnsSlow` still reports
            // `.reconnect` while the policy is `.noAction` — Codex P2), threading the same
            // `reason` so the ceiling matches. Only commit + cancel while the policy STILL
            // says reconnect; otherwise release the latch and bail (recovery owns its probe).
            let revalidatedAssessment = ProtectionConnectivityPolicy.assessment(
                isConnected: true,
                health: self.health,
                now: now
            )
            let revalidatedDecision = TunnelSelfReconnectPolicy.decision(
                assessment: revalidatedAssessment,
                protectionEnabled: self.currentAppConfiguration().protectionEnabled,
                onDemandEnabled: Self.isOnDemandConfirmedEnabled(),
                recentReconnectTimes: attempts,
                reason: reason,
                now: now
            )
            guard revalidatedDecision == .reconnect else {
                self.hasRequestedSelfReconnect = false
                return
            }
            // Re-check the freshest delivered path AND health. The teardown is issued in THIS
            // same synchronous dnsStateQueue block — no main-queue hop — so the path cannot
            // flip between this guard and the cancel, and the persisted attempt is never
            // burned for a skipped teardown (Codex P2 + Track 1). cancelTunnelWithError is
            // async to iOS, and setTunnelNetworkSettings is already invoked off-main here, so
            // an off-main cancel is safe and keeps the path check + teardown atomic.
            guard self.latestMonitoredPathIsSatisfied, self.health.networkPathIsSatisfied else {
                self.hasRequestedSelfReconnect = false
                let cooldownElapsed = self.lastSelfReconnectPathSkipLogAt.map {
                    now.timeIntervalSince($0) >= Self.selfReconnectSuppressionLogInterval
                } ?? true
                if cooldownElapsed {
                    self.lastSelfReconnectPathSkipLogAt = now
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-skipped-path-unsatisfied", details: [
                        "reason": self.health.lastFailureReason ?? "dns-wedged"
                    ])
                }
                self.scheduleResolverWedgeRecoveryProbeIfNeeded()
                return
            }

            let updatedAttempts = TunnelSelfReconnectPolicy.prunedAttemptTimes(attempts, now: now) + [now]
            Self.saveSelfReconnectAttemptTimes(updatedAttempts)
            // Persist a restart-survivable "a self-reconnect was committed at `now`" marker
            // BEFORE the cancel (which kills the process). The NEXT launch's first confirmed
            // primary recovery credits this attempt back (creditProductiveSelfReconnectIfPending),
            // so a productive restart nets ~0 against the cap while a true loop — which never
            // reaches a post-restart recovery — accrues to the ceiling. Must be persisted, NOT
            // tracked via the in-memory `reconnectNeededSince` wedge marker, which the cancel
            // wipes (the relaunched process would never credit otherwise).
            Self.saveLastSelfReconnectAt(now)
            // Durable GAP evidence, decoupled from the rate-limiter's stores (which forget by
            // design: the credit deletes the recovered attempt, the marker above is one-shot,
            // the report prunes to the 600 s window). Start stamped here; the ended marker is
            // CLEARED so the pair can only ever describe THIS gap — the relaunched process
            // stamps it at startTunnel when it is serving again. Never read by
            // TunnelSelfReconnectPolicy, so the cap/cooldown inputs are untouched.
            Self.openSelfReconnectGap(at: now)
            // Ledger record BEFORE the cancel below kills the process (synchronous write —
            // the async hop would not survive cancelTunnelWithError; CON-1). Bounded by the
            // non-blocking lock, and at teardown there is no ongoing DNS to stall.
            Self.recordIncident(
                .selfReconnectCommitted,
                reason: self.health.lastFailureReason ?? "dns-wedged",
                now: now,
                synchronous: true
            )

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect", details: [
                "reason": self.health.lastFailureReason ?? "dns-wedged",
                "restartReason": "\(reason)",
                "attemptsInWindow": "\(updatedAttempts.count)"
            ])

            self.cancelTunnelWithError(nil)
        }
    }

    // Confirmed by the app only after `saveToPreferences` arms Connect-On-Demand.
    // Defaults to false (never armed) so a missing/failed-to-arm signal suppresses
    // self-reconnect rather than risking a cancel with no automatic recovery.
    private static func isOnDemandConfirmedEnabled() -> Bool {
        LavaSecAppGroup.sharedDefaults.bool(
            forKey: LavaSecAppGroup.protectionOnDemandConfirmedEnabledDefaultsKey
        )
    }

    private static func loadSelfReconnectAttemptTimes() -> [Date] {
        let raw = LavaSecAppGroup.sharedDefaults.array(forKey: selfReconnectAttemptsDefaultsKey) as? [Double] ?? []
        return raw.map(Date.init(timeIntervalSince1970:))
    }

    private static func saveSelfReconnectAttemptTimes(_ times: [Date]) {
        LavaSecAppGroup.sharedDefaults.set(
            times.map(\.timeIntervalSince1970),
            forKey: selfReconnectAttemptsDefaultsKey
        )
    }

    private static func loadLastSelfReconnectAt() -> Date? {
        let raw = LavaSecAppGroup.sharedDefaults.double(forKey: lastSelfReconnectAtDefaultsKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private static func launchFollowsRecentSelfReconnect(now: Date) -> Bool {
        guard let lastSelfReconnectAt = loadLastSelfReconnectAt() else {
            return false
        }

        let age = now.timeIntervalSince(lastSelfReconnectAt)
        return age >= 0 && age <= selfReconnectCreditWindow
    }

    private static func saveLastSelfReconnectAt(_ date: Date) {
        LavaSecAppGroup.sharedDefaults.set(date.timeIntervalSince1970, forKey: lastSelfReconnectAtDefaultsKey)
    }

    private static func clearLastSelfReconnectAt() {
        LavaSecAppGroup.sharedDefaults.removeObject(forKey: lastSelfReconnectAtDefaultsKey)
    }

    // CON-1: INCIDENT-LEDGER IO runs on this dedicated SERIAL queue, never dnsStateQueue —
    // so a cross-process flock a suspended app holds can never wedge DNS serving. Serial ⇒
    // append order is preserved. Static so the static `recordIncident` can use it too.
    //
    // The terminal self-reconnect commit drains this queue via `sync` before
    // cancelTunnelWithError (see `recordIncident`), so EVERYTHING enqueued here MUST use the
    // non-blocking bounded lock — append, sweepExpired, and the tunnel-side `tryClear`. A
    // blocking op here could wait indefinitely on a flock a suspended app holds, and the
    // teardown draining behind it would stall, recreating the very DNS outage this change
    // prevents (Codex #200 P2). NetworkActivity IO lives on its OWN queue below for exactly
    // this reason — its clear is BLOCKING and its flock is heavily app-contended, so it must
    // never share the queue the terminal `sync` drains.
    static let appGroupLogIOQueue = DispatchQueue(label: "com.lavasec.tunnel.app-group-log-io", qos: .utility)

    // CON-1: NETWORK-ACTIVITY IO on its OWN serial queue, split from the incident ledger
    // (Codex #200 P2). Two independent files with no cross-file ordering requirement, so
    // splitting is safe and each queue still serializes its own file's append-vs-clear
    // (anti-resurrection). The split matters because the network-activity flock is heavily
    // cross-process contended — the app's blocking `append` and `loadPruned` both hold it —
    // so its clear stays BLOCKING/reliable (a user privacy wipe must not silently drop). That
    // is safe HERE because no terminal `sync` drains this queue: a blocked clear delays only
    // its own completion, never DNS serving or the self-reconnect teardown.
    static let networkActivityLogIOQueue = DispatchQueue(label: "com.lavasec.tunnel.network-activity-log-io", qos: .utility)

    // OBS R2: the append-only incident ledger. Observability-only, exactly like the gap
    // pair below: nothing in the recovery/cap policy reads the ledger, writes add no
    // control flow at their call sites, and the file lives outside the rate-limiter's
    // stores (which forget by design — productive credit, 600s prune, resetHealth), so a
    // late-filed report still carries the incident timeline.
    //
    // CON-1: the ledger append hops onto `appGroupLogIOQueue` (off dnsStateQueue) with a
    // non-blocking bounded lock, so it can never stall DNS. The terminal self-reconnect
    // commit sets the `synchronous` flag: it still runs ON `appGroupLogIOQueue` (so it keeps
    // append order behind any queued incidents), but via `sync` so it lands durably BEFORE
    // cancelTunnelWithError tears the process down. At teardown there is no ongoing DNS to
    // stall, and the drain is bounded by the non-blocking lock on each queued write.
    private static func recordIncident(
        _ kind: IncidentLedgerRecord.Kind,
        reason: String? = nil,
        durationMs: Int? = nil,
        verifiedBy: String? = nil,
        now: Date = Date(),
        synchronous: Bool = false
    ) {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return
        }
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        let record = IncidentLedgerRecord(
            at: now,
            kind: kind,
            reason: reason,
            durationMs: durationMs,
            verifiedBy: verifiedBy
        )
        guard !synchronous else {
            // Terminal self-reconnect commit: still serialized on appGroupLogIOQueue, but
            // via `sync` (CON-1, Codex #200). `sync` drains every already-enqueued async
            // incident first — so the append-only timeline can't show the restart before
            // the incident that triggered it — then writes and RETURNS before
            // cancelTunnelWithError tears the process down (durable). Deadlock-safe: this
            // runs off the self-reconnect teardown queue, never appGroupLogIOQueue itself,
            // and IO-queue blocks never re-enter that queue.
            appGroupLogIOQueue.sync {
                IncidentLedgerPersistence.append(record, to: ledgerURL)
                // `append` returns Bool, so this trailing closure infers `() -> Bool` and Swift
                // resolves to DispatchQueue's generic `sync<T>` overload (T = Bool); the Bool it
                // returns is unused at the call site → "result of call to 'sync(execute:)' is
                // unused". The explicit Void return pins the closure to `() -> Void`, selecting the
                // non-generic `sync(execute:)`. (`append` is @discardableResult, so the inner call
                // itself never warns — that attribute does not affect this overload resolution.)
                return
            }
            return
        }
        appGroupLogIOQueue.async {
            IncidentLedgerPersistence.append(record, to: ledgerURL)
        }
    }

    // Startup retention sweep for the ledger file. The tunnel never reads ledger
    // CONTENTS (the frozen recovery path takes no input from it) — this call only
    // arms/confirms the two-phase expiry inside the persistence lock and discards
    // everything else. CON-1: hopped onto appGroupLogIOQueue with the non-blocking
    // bounded lock, so it never writes synchronously inside startTunnel /
    // loadInitialSharedState and can never stall the startup path on a held lock.
    private static func sweepIncidentLedger() {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return
        }
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        appGroupLogIOQueue.async {
            IncidentLedgerPersistence.sweepExpired(at: ledgerURL)
        }
    }

    // Durable self-reconnect gap pair (LAV-92/93 observability; keys documented in
    // LavaSecAppGroup). Observability-only: nothing in the recovery/cap policy reads these.
    private static func openSelfReconnectGap(at now: Date) {
        let defaults = LavaSecAppGroup.sharedDefaults
        // Clear the previous end BEFORE publishing the new start: the two writes are not
        // atomic across processes, and the reverse order lets a concurrent reader pair the
        // NEW start with the OLD end (a bogus zero/negative "closed" gap masking an open
        // outage). This order's worst interleave is the conservative one — the previous gap
        // briefly reads as still open. Readers additionally ignore any end that is not
        // AFTER the start they loaded, covering an extension killed between the writes.
        defaults.removeObject(forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKey)
        defaults.set(now.timeIntervalSince1970, forKey: LavaSecAppGroup.selfReconnectGapStartedAtDefaultsKey)
        defaults.set(
            defaults.integer(forKey: LavaSecAppGroup.selfReconnectGapCountDefaultsKey) + 1,
            forKey: LavaSecAppGroup.selfReconnectGapCountDefaultsKey
        )
    }

    // Closes the Guard-off window a committed self-reconnect opened. Called from the
    // startTunnel READY point (settings installed, packets flowing — fail-closed counts as
    // serving, no leak either way), never at entry: a failed settings install leaves the gap
    // open, which is the truth. If Connect-On-Demand never relaunched us and the user toggled
    // manually hours later, the long duration is exactly the honest signal (the LAV-92/93
    // residual).
    private static func closeDanglingSelfReconnectGapIfNeeded(now: Date = Date()) {
        let defaults = LavaSecAppGroup.sharedDefaults
        let startedAtRaw = defaults.double(forKey: LavaSecAppGroup.selfReconnectGapStartedAtDefaultsKey)
        // A gap is genuinely closed only when its end is AFTER its start: an end at or
        // before the start is a stale leftover from the PREVIOUS gap (the extension can die
        // between the open's two writes), and skipping on it would leave the new gap
        // unclosed forever. Overwrite it with the honest close instead.
        let endedAtRaw = defaults.double(forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKey)
        guard startedAtRaw > 0, endedAtRaw <= startedAtRaw else {
            return
        }
        // COH-2: the reader accepts an end only if it is STRICTLY AFTER the start. A backward
        // wall-clock step larger than the relaunch latency makes `now <= startedAt`, so stamping
        // a raw `now` here writes `ended <= started` — which the app reader rejects as stale and
        // reads the gap as still OPEN forever (every bug report then flags an ongoing incident
        // while serving normally). Floor the end at `startedAt + 1s` so it reads as closed; this
        // is observability-only (the marker, never the reconnect decision) and self-heals the
        // moment the clock passes the recorded start.
        let nowRaw = now.timeIntervalSince1970
        let clockWentBackward = nowRaw <= startedAtRaw
        let endedRaw = clockWentBackward ? startedAtRaw + 1 : nowRaw
        defaults.set(endedRaw, forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKey)
        let gapMilliseconds = max(0, Int(((endedRaw - startedAtRaw) * 1_000).rounded()))
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-gap-closed", details: [
            "gapMs": "\(gapMilliseconds)",
            "clockAnomaly": "\(clockWentBackward)"
        ])
    }

    // Productive-recovery credit (Track 4). Called from the confirmed PRIMARY/device-DNS
    // recovery sites (the smoke-probe success handlers — event-driven, NOT the per-query
    // hot path). If a self-reconnect was committed before this launch (persisted
    // `lastSelfReconnectAt`) and we've now recovered within the credit window, that restart
    // was PRODUCTIVE: remove ONLY that restart's own attempt from the shared store, leaving
    // any earlier UNproductive attempts counted so the cap still bounds a restart-without-
    // recovery loop (Codex P2). Decoupled from the in-memory wedge marker on purpose — that
    // marker does not survive the cancel's process kill, so crediting through it would be a
    // no-op for the cold restart this serves.
    private func creditProductiveSelfReconnectIfPending(now: Date) {
        guard let lastSelfReconnectAt = Self.loadLastSelfReconnectAt() else {
            return
        }
        // One-shot regardless of outcome: a stale marker must not keep crediting.
        Self.clearLastSelfReconnectAt()
        guard now.timeIntervalSince(lastSelfReconnectAt) <= Self.selfReconnectCreditWindow else {
            return
        }
        // Remove a SINGLE matching attempt — the one stamped for the restart that recovered
        // (the marker and the persisted attempt are the same instant) — not every attempt at-
        // or-before it. Crediting all of them would erase earlier failures and let an
        // intermittent loop exceed the per-window cap after one success (Codex P2).
        var remaining = Self.loadSelfReconnectAttemptTimes()
        if let creditedIndex = remaining.firstIndex(of: lastSelfReconnectAt) {
            remaining.remove(at: creditedIndex)
        }
        Self.saveSelfReconnectAttemptTimes(remaining)
        // The credit DELETES the attempt from the policy store (correct for the cap) —
        // the ledger record is what survives to a late-filed report.
        Self.recordIncident(
            .selfReconnectCredited,
            durationMs: max(0, Int((now.timeIntervalSince(lastSelfReconnectAt) * 1_000).rounded())),
            now: now
        )
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "self-reconnect-credited", details: [
            "recoveredAfterMs": "\(max(0, Int((now.timeIntervalSince(lastSelfReconnectAt) * 1_000).rounded())))",
            "attemptsRemaining": "\(remaining.count)"
        ])
    }

    // Pairs a logged "Reconnect needed" with a visible recovery row + a firm
    // device-log line (mechanism + true wedge duration). Call BEFORE
    // clearReconnectNeededActivitySuppression (which drops the wedge state). Fires
    // only when a wedge is in progress (reconnectNeededSince set), so it no-ops on
    // ordinary successes and routine probes. Both the organic-query path
    // (recordUpstreamResult) and the in-place smoke-probe recovery path
    // (applyResolverSmokeProbeResult) route through here, so a self-recovery that
    // never sees an organic query is still recorded.
    // `verifiedBy` distinguishes a recovery proven by a real client query that
    // resolved through the tunnel ("forwarding", the full downstream path) from one
    // seen only by the smoke probe ("smoke-probe", the provider→resolver upstream
    // leg). The two can diverge — the probe can pass while the device still isn't
    // routing DNS through the tunnel — so recording which proved it makes a
    // "recovered but the user still had to toggle" incident diagnosable from the log.
    private func logConnectivityRecoveredIfWedged(
        transport: DNSResolverTransport,
        verifiedBy: String,
        now: Date
    ) {
        guard let wedgeStart = reconnectNeededSince else {
            return
        }

        let durationMs = max(0, Int((now.timeIntervalSince(wedgeStart) * 1_000).rounded()))
        let failureReason = reconnectNeededReason ?? "dns-wedged"
        // Carry the wedge's failure reason (not just the transport) so the recovery
        // row pairs 1:1 with its "Reconnect needed: <reason>" and two distinct-cause
        // wedges that recover within the activity log's 30s duplicate-coalescing
        // window aren't collapsed into one row. (Same-cause+same-transport recoveries
        // within 30s still coalesce — they're indistinguishable in the summary; the
        // un-coalesced device-log dns-recovered below keeps the per-recovery detail.)
        appendNetworkActivity(
            event: .connectivityRecovered(reason: "\(failureReason) via \(transport.rawValue)"),
            now: now
        )
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-recovered", details: [
            "reason": failureReason,
            "transport": transport.rawValue,
            "verifiedBy": verifiedBy,
            "durationMs": "\(durationMs)",
            "consecutiveUpstreamFailureCount": "\(reconnectNeededPeakFailureCount)"
        ])
        Self.recordIncident(
            .wedgeRecovered,
            reason: failureReason,
            durationMs: durationMs,
            verifiedBy: verifiedBy,
            now: now
        )
        // The wedge marker is owned here (and by the lifecycle reset): clearing it
        // only after a recovery is logged is what lets a handoff recovery — which
        // passes through clearReconnectNeededActivitySuppression on the network
        // change before recovering — still be captured.
        reconnectNeededSince = nil
        reconnectNeededReason = nil
        reconnectNeededPeakFailureCount = 0
        // The wedge ended, so the next one should log its suppression fresh.
        lastSelfReconnectSuppressionSignature = nil
        lastSelfReconnectSuppressionLogAt = nil
        lastSelfReconnectPathSkipLogAt = nil
        // Close the coalesced encrypted-fallback episode here too: this is the single
        // authoritative recovery point (both the organic-query and the smoke-probe
        // recovery route through it), so a wedge that recovers via the smoke probe with
        // no intervening primary query still lets the next wedge log its first carried
        // query — the episode-level diagnostic contract.
        clearEncryptedFallbackLogThrottle()
    }

    private func clearReconnectNeededActivitySuppression() {
        lastReconnectNeededActivityAt = nil
        // NOTE: reconnectNeededSince/Reason are deliberately NOT cleared here. This
        // runs on the network-change/wake reset path too (before the settle probe
        // recovers), and clearing the wedge marker there would make the handoff
        // recovery silently no-op. The marker is cleared only by a logged recovery
        // (logConnectivityRecoveredIfWedged) or a tunnel-lifecycle reset (resetHealth).
        // DNS recovered (or the runtime was reset for recovery): drop any pending
        // wedge-recovery re-probe so it can't reset a now-healthy resolver.
        cancelResolverWedgeRecoveryProbe()
        // A recapture restart is owed only while DNS is wedged; once recovered (or
        // reset for recovery) drop it so a later unrelated wedge uses the wedge ceiling.
        deviceDNSRecaptureRestartPending = false
    }

    #if LAVA_QA_TOOLS
    private func logQAConnectivityAssessmentIfNeeded(reason: String, now: Date) {
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        let severity = assessment.severity
        let isProblem = severity == .needsReconnect
            || severity == .networkUnavailable
            || severity == .usingDeviceDNSFallback
            || severity == .usingEncryptedFallback
        let didChangeSeverity = severity != lastQAConnectivitySeverity
        let isThrottledProblemReminder = isProblem && now.timeIntervalSince(lastQAConnectivityLogAt) >= 300

        guard didChangeSeverity || isThrottledProblemReminder else {
            return
        }

        lastQAConnectivitySeverity = severity
        lastQAConnectivityLogAt = now

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "qa-connectivity-assessment", details: [
            "reason": reason,
            "severity": String(describing: severity),
            "primaryAction": String(describing: assessment.primaryAction),
            "networkKind": health.networkKind.rawValue,
            "networkPathIsSatisfied": "\(health.networkPathIsSatisfied)",
            "lastFailureReason": health.lastFailureReason ?? "nil",
            "lastResolverTransport": health.lastResolverTransport.rawValue,
            "upstreamSuccessCount": "\(health.upstreamSuccessCount)",
            "upstreamFailureCount": "\(health.upstreamFailureCount)",
            "consecutiveUpstreamFailureCount": "\(health.consecutiveUpstreamFailureCount)",
            "upstreamTimeoutCount": "\(health.upstreamTimeoutCount)",
            "dnsSmokeProbeSuccessCount": "\(health.dnsSmokeProbeSuccessCount)",
            "dnsSmokeProbeFailureCount": "\(health.dnsSmokeProbeFailureCount)",
            "lastDNSSmokeProbeSucceeded": health.lastDNSSmokeProbeSucceeded.map { "\($0)" } ?? "nil",
            "deviceDNSFallbackActivationCount": "\(health.deviceDNSFallbackActivationCount)",
            "deviceDNSFallbackModeActive": "\(deviceDNSFallbackModeActive)",
            "resolverRuntimeResetCount": "\(health.resolverRuntimeResetCount)",
            "lastNetworkChangeAt": Self.qaDebugDateString(health.lastNetworkChangeAt),
            "lastResolverRuntimeResetAt": Self.qaDebugDateString(health.lastResolverRuntimeResetAt),
            "lastUpstreamSuccessAt": Self.qaDebugDateString(health.lastUpstreamSuccessAt),
            "lastUpstreamFailureAt": Self.qaDebugDateString(health.lastUpstreamFailureAt),
            "lastDNSSmokeProbeAt": Self.qaDebugDateString(health.lastDNSSmokeProbeAt)
        ])
    }

    private static func qaDebugDateString(_ date: Date?) -> String {
        guard let date else {
            return "nil"
        }

        return SharedDateFormatting.iso8601.string(from: date)
    }
    #endif

    private func applyDiagnosticsControlIfNeeded(force: Bool = false) {
        guard let diagnosticsControlURL else {
            return
        }

        let modifiedAt = modificationDate(for: diagnosticsControlURL)
        guard force || modifiedAt != lastDiagnosticsControlModifiedAt else {
            return
        }

        lastDiagnosticsControlModifiedAt = modifiedAt
        let control = DiagnosticsControlPersistence.load(from: diagnosticsControlURL)
        var didApplyControl = false

        // Dedup against the DURABLE applied-marker on the store (PST-1): only apply a
        // control request strictly newer than the clear this store already carries, so a
        // force-apply on every start can't re-wipe data accumulated since the clear. The
        // clear methods stamp the marker to `requestedAt`, so the next start's gate is
        // `requestedAt > requestedAt` = false.
        if let requestedAt = control.clearDomainHistoryRequestedAt,
           requestedAt > (diagnostics.lastAppliedDomainHistoryClearAt ?? .distantPast) {
            diagnostics.clearDomainHistory(clearedAt: requestedAt)
            didApplyControl = true
        }

        if let requestedAt = control.clearFilteringCountsRequestedAt,
           requestedAt > (diagnostics.lastAppliedFilteringCountsClearAt ?? .distantPast) {
            diagnostics.clearFilteringCounts(startedAt: requestedAt)
            didApplyControl = true
        }

        if didApplyControl {
            markDiagnosticsUpdated()
        }
    }

    private func markDiagnosticsUpdated() {
        diagnosticsPersistence.markDirty()
    }

    private func persistDiagnosticsIfNeeded(force: Bool = false) {
        diagnosticsPersistence.flush(force: force)
    }

    // MARK: - Configuration & device-DNS state accessors

    private func currentNetworkKind() -> TunnelNetworkKind {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return networkKind
        }

        return dnsStateQueue.sync {
            networkKind
        }
    }

    private func currentDeviceDNSResolverAddresses() -> [String] {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return deviceDNSResolverAddresses
        }

        return dnsStateQueue.sync {
            deviceDNSResolverAddresses
        }
    }

    @discardableResult
    private func setDeviceDNSResolverAddresses(
        _ addresses: [String],
        preserveOnEmptyCapture: Bool = true
    ) -> [String] {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: addresses,
                preserveOnEmptyCapture: preserveOnEmptyCapture
            )
            return deviceDNSResolverAddresses
        }

        return dnsStateQueue.sync {
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: addresses,
                preserveOnEmptyCapture: preserveOnEmptyCapture
            )
            return deviceDNSResolverAddresses
        }
    }

    private func currentDeviceDNSFallbackModeActive() -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return deviceDNSFallbackModeActive
        }

        return dnsStateQueue.sync {
            deviceDNSFallbackModeActive
        }
    }

    private func refreshDeviceDNSResolverAddresses(
        reason: String,
        preserveOnEmptyCapture: Bool = true
    ) {
        let addresses = Self.currentSystemDNSServerAddresses()
        let activeAddresses = setDeviceDNSResolverAddresses(
            addresses,
            preserveOnEmptyCapture: preserveOnEmptyCapture
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-captured", details: [
            "reason": reason,
            "count": "\(addresses.count)",
            "activeCount": "\(activeAddresses.count)"
        ])
    }

    private func refreshDeviceDNSResolverAddressesOnDNSQueue(
        reason: String,
        preserveOnEmptyCapture: Bool = true
    ) {
        let addresses = Self.currentSystemDNSServerAddresses()
        deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
            current: deviceDNSResolverAddresses,
            captured: addresses,
            preserveOnEmptyCapture: preserveOnEmptyCapture
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-captured", details: [
            "reason": reason,
            "count": "\(addresses.count)",
            "activeCount": "\(deviceDNSResolverAddresses.count)"
        ])
    }

    private static func currentSystemDNSServerAddresses() -> [String] {
        var buffer = [CChar](repeating: 0, count: deviceDNSCaptureBufferLength)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else {
                return 0
            }

            return LavaSecCopySystemDNSServers(baseAddress, Int32(pointer.count))
        }

        guard count > 0 else {
            return []
        }

        let capturedBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let captured = String(decoding: capturedBytes, as: UTF8.self)
        var uniqueAddresses: [String] = []
        var seenAddresses: Set<String> = []

        for address in captured.split(separator: "\n").map(String.init) where isUsableDeviceDNSServer(address) {
            guard seenAddresses.insert(address).inserted else {
                continue
            }

            uniqueAddresses.append(address)
        }

        return uniqueAddresses
    }

    private static func isUsableDeviceDNSServer(_ address: String) -> Bool {
        // Reject the tunnel's own listener (config-specific), then defer the structural
        // reserved/unroutable-range rejection (unspecified/loopback/link-local/NAT64) to
        // the pure, unit-tested policy predicate. Phase 0 hygiene (lavasec-infra#57):
        // a half-configured post-handoff link can surface a link-local/NAT64 address
        // before the real resolver settles; adopting one wedges DNS on a dead address.
        guard address != tunnelDNSServerAddress else {
            return false
        }

        return DeviceDNSFallbackPolicy.isUsableResolverAddress(address)
    }

    private func currentAppConfiguration() -> AppConfiguration {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return appConfiguration
        }

        return dnsStateQueue.sync {
            appConfiguration
        }
    }

    private func setAppConfiguration(_ configuration: AppConfiguration) {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            appConfiguration = configuration
            return
        }

        dnsStateQueue.sync {
            appConfiguration = configuration
        }
    }

    private static func tunnelNetworkKind(for path: Network.NWPath) -> TunnelNetworkKind {
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }

        if path.usesInterfaceType(.wifi) {
            return .wifi
        }

        if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        }

        return path.status == .satisfied ? .other : .unknown
    }

    private static func pathStatusDescription(_ status: Network.NWPath.Status) -> String {
        switch status {
        case .satisfied:
            "satisfied"
        case .unsatisfied:
            "unsatisfied"
        case .requiresConnection:
            "requires-connection"
        @unknown default:
            "unknown"
        }
    }

    // Runs on dnsStateQueue (the DNS handling path); the elapsed time is
    // measured from setTunnelNetworkSettings success per the plan's
    // "first DNS after tunnel start" latency target.
    private func recordFirstDNSDecisionIfNeeded(_ decision: String) {
        guard !hasRecordedFirstDNSDecision else {
            return
        }

        hasRecordedFirstDNSDecision = true

        #if DEBUG || LAVA_QA_TOOLS
        let elapsedMs = firstDNSDecisionReferenceAt.map { Int((Date().timeIntervalSince($0) * 1_000).rounded()) }
        let trace = Self.makeLatencyTrace(operationID: tunnelStartLatencyOperationID, operationKind: "tunnelStart")
        trace.record("tunnel.firstDNSDecision", details: [
            "decision": decision,
            "elapsedMs": elapsedMs.map(String.init) ?? "unknown"
        ])
        #endif
    }

    // Pause flips deliberately do NOT reset the DNS runtime or reload the
    // snapshot: the policy snapshot stays loaded during pause, pause-era cached
    // answers carry TTLs capped to the pause window, and pending forwards
    // re-check policy at completion. Refreshing pause state and the expiry
    // timer is sufficient (plan F2 / Track 5).
    private func refreshProtectionPauseStateOnly(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.refreshProtectionPauseStateOnly(reason: reason)
            }
            return
        }

        let pauseUntil = refreshTemporaryProtectionPauseState(synchronizesDefaults: true)
        let pauseIsActive = pauseUntil.map { $0 > Date() } ?? false
        let didChangePauseActivity = pauseIsActive != lastAppliedTemporaryProtectionPauseIsActive
        lastAppliedTemporaryProtectionPauseIsActive = pauseIsActive
        scheduleProtectionPauseResumeIfNeeded(reason: reason)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "pause-state-refreshed", details: [
            "reason": reason,
            "pauseActive": "\(pauseIsActive)",
            "changed": "\(didChangePauseActivity)"
        ])
        #endif
    }

    // MARK: - Snapshot reload orchestration

    private func requestSnapshotReload(reason: String, force: Bool = false, operationID: LatencyOperationID? = nil) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.requestSnapshotReload(reason: reason, force: force, operationID: operationID)
            }
            return
        }

        let pauseUntil = refreshTemporaryProtectionPauseState(synchronizesDefaults: true)
        let pauseIsActive = pauseUntil.map { $0 > Date() } ?? false
        let didChangePauseActivity = pauseIsActive != lastAppliedTemporaryProtectionPauseIsActive
        lastAppliedTemporaryProtectionPauseIsActive = pauseIsActive
        scheduleProtectionPauseResumeIfNeeded(reason: reason)

        guard force || didChangePauseActivity else {
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "snapshot-reload-skipped", details: [
                "reason": reason,
                "pauseActive": "\(pauseIsActive)"
            ])
            #endif
            return
        }

        resetDNSRuntimeForProtectionPolicyChange(reason: reason)
        loadSnapshotInBackground(reason: reason, operationID: operationID)
    }

    private func nextSnapshotReloadGeneration() -> UInt64 {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            return dnsStateQueue.sync {
                nextSnapshotReloadGeneration()
            }
        }

        snapshotReloadGeneration += 1
        // A reload is now starting and is the latest. Mark it in flight so the Focus config poll won't bump
        // the generation out from under it (cleared when this load resolves — see clearSnapshotReloadInFlight).
        snapshotReloadInFlight = true
        return snapshotReloadGeneration
    }

    /// Clear the in-flight marker when a load resolves, but ONLY if it is still the latest reload — an
    /// overlapping newer load (a concurrent app provider-message reload) keeps ownership and clears it itself.
    /// dnsStateQueue-confined, mirroring the other reload-generation bookkeeping.
    private func clearSnapshotReloadInFlight(ifCurrentGeneration generation: UInt64) {
        dnsStateQueue.async { [weak self] in
            guard let self else { return }
            // dnsStateQueue-confined invariant (Kilo #29): see advanceFocusConfigurationWatermark — the clear
            // is FIFO-after the watermark advance only because both run on this queue. Assert so an off-queue
            // refactor trips.
            dispatchPrecondition(condition: .onQueue(self.dnsStateQueue))
            guard self.isCurrentSnapshotReloadGeneration(generation) else { return }
            self.snapshotReloadInFlight = false
        }
    }

    private func isCurrentSnapshotReloadGeneration(_ generation: UInt64) -> Bool {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            return dnsStateQueue.sync {
                isCurrentSnapshotReloadGeneration(generation)
            }
        }

        return generation == snapshotReloadGeneration
    }

    private func invalidateSnapshotReloadGeneration(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.invalidateSnapshotReloadGeneration(reason: reason)
            }
            return
        }

        snapshotReloadGeneration += 1
        // An invalidation abandons any in-flight load (it will be rejected by the generation gate), and no new
        // load follows — so clear the in-flight marker, else the poll would skip forever waiting on a load that
        // will never resolve.
        snapshotReloadInFlight = false

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "snapshot-reload-invalidated", details: [
            "reason": reason,
            "generation": "\(snapshotReloadGeneration)"
        ])
        #endif
    }

    private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil) {
        let generation = nextSnapshotReloadGeneration()
        #if DEBUG || LAVA_QA_TOOLS
        // Joins the caller's operation (tunnel start or a provider reload) so
        // app action spans and the tunnel's snapshot work share one id.
        let trace = Self.makeLatencyTrace(operationID: operationID, operationKind: "snapshotReload")
        let loadSpan = trace.beginSpan("tunnel.snapshotLoad", details: [
            "reason": reason,
            "generation": "\(generation)"
        ])
        #endif

        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                #if DEBUG || LAVA_QA_TOOLS
                loadSpan.end(details: ["status": "missing-provider"])
                #endif
                return
            }
            // Clear the in-flight marker once the (expensive) load body finishes via ANY of its returns, so the
            // poll can fire the next reload. Generation-gated, so a newer overlapping load keeps the marker
            // (Codex round 5). CORRECTNESS INVARIANT: this clear is `dnsStateQueue.async`, enqueued from `defer`
            // when the SYNCHRONOUS body returns — therefore strictly FIFO-AFTER the watermark advance the body
            // already enqueued (advanceFocusConfigurationWatermark). A poll tick that later observes the marker
            // cleared is dequeued after this clear, hence after that watermark advance, so it never sees a stale
            // watermark. Do NOT move a watermark advance into a nested async block that could run AFTER this
            // defer, or that invariant breaks.
            defer { self.clearSnapshotReloadInFlight(ifCurrentGeneration: generation) }

            let startedAt = Date()
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-begin", details: [
                "generation": "\(generation)",
                "reason": reason
            ])

            let configuration = self.loadConfiguration() ?? self.currentAppConfiguration()

            // Pre-decode no-op gate: if the on-disk artifact would reproduce the
            // resident snapshot, skip the multi-megabyte decode entirely. This
            // is the common pull-to-refresh-with-no-content-change case and
            // avoids the 2x-resident memory peak that jetsams the extension on
            // large multi-list snapshots.
            if self.residentSnapshotSatisfiesReload(configuration: configuration) {
                // Resident already satisfies the reload → it is a healthy real snapshot.
                self.clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration: generation)
                // The resident already covers this config ⇒ the tunnel has effectively ADOPTED this
                // generation, so advance the Focus config-poll watermark here too — otherwise a config-only
                // / equivalent-filter generation bump would never advance it and the poll would force a
                // reload (+ DNS-runtime reset) every interval (Codex P2). Same guarded advance as a full adopt.
                self.advanceFocusConfigurationWatermark(
                    toAdoptedGeneration: configuration.configurationGeneration,
                    ifCurrentReloadGeneration: generation
                )
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-reload-noop", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                loadSpan.end(details: ["status": "noop"])
                #endif
                return
            }

            // Backstop for the app's compile-time budget guardrail: never decode
            // an over-budget artifact (it would jetsam the extension). Read the
            // header only, and if it exceeds the rule budget, stay FAIL-CLOSED
            // (block all) rather than crash. The app's guardrail is the primary
            // path and surfaces the actionable message; this catches artifacts
            // written before a budget change or by an older build.
            // This gate is compact-header-only by design; the prepared fallback
            // self-guards post-decode in `reusablePreparedSnapshot`, so it is not
            // load-bearing for prepared-only artifacts.
            if let overBudgetRuleCount = self.compactSnapshotRuleCountExceedingBudget(configuration: configuration) {
                // Over-budget is snapshot-unavailable (we can't serve it without jetsam);
                // a restart can't shrink it, so mark it so the resulting probe failure
                // doesn't drive a self-reconnect loop. Flag committed atomically with the
                // fail-closed snapshot under the generation gate.
                let wasFailClosedBeforeOverBudget = self.isResidentFailClosedDueToUnavailableSnapshot()
                let didCommitFailClosed = self.replaceSnapshot(
                    FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset),
                    identity: nil,
                    failClosedDueToUnavailableSnapshot: true,
                    generation: generation
                )
                // Ledger record stays OUTSIDE the QA-gated append below — a Release
                // user's fail-closed entry must reach the report too. Gated on the
                // commit LANDING (a superseded reload's no-op never served fail-closed)
                // AND on the TRANSITION: the Focus poll retries an unadoptable
                // generation once per minute, and per-retry records would flood the
                // 50-record ring and evict the original incident.
                if didCommitFailClosed, !wasFailClosedBeforeOverBudget {
                    Self.recordIncident(.failClosedEntered, reason: "snapshot-unavailable")
                }
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-over-budget", details: [
                    "generation": "\(generation)",
                    "reason": reason,
                    "ruleCount": "\(overBudgetRuleCount)",
                    "maxRuleCount": "\(FilterSnapshotMemoryBudget.maxFilterRuleCount)"
                ])
                loadSpan.end(details: ["status": "over-budget"])
                #endif
                self.dnsStateQueue.async { [weak self] in
                    guard let self, self.isCurrentSnapshotReloadGeneration(generation) else {
                        return
                    }
                    self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                }
                if didCommitFailClosed {
                    self.failTransientBootstrapDNSWait(reason: "snapshot-unavailable-\(reason)")
                }
                return
            }

            // Genuine change replacing a resident snapshot with a new lists-enabled
            // (large) one. Freeing the resident BEFORE decoding keeps peak memory ~1x,
            // but it is only safe to discard last-known-good when the new snapshot is
            // all-but-certain to load. We free pre-decode ONLY when a reusable, in-budget
            // on-disk compact artifact is present (the fast path that cannot fail short of
            // a rare GC race). If there is NO reusable artifact — the new config can only
            // be satisfied by an in-extension recompile, which CAN fail (e.g. a blocklist
            // whose upstream rotated past the catalog's pinned hash) — we keep the resident
            // so a failed reload degrades to "keep the last-known-good lists" instead of
            // wedging fail-closed into a self-reconnect flicker loop. Skipped at tunnel
            // start (no resident yet) where peak is already 1x.
            let hasResidentSnapshot = self.currentResidentSnapshotIdentity() != nil
            let hasReusableArtifact = self.readCompactSnapshotSummary(configuration: configuration) != nil
            let freedResidentBeforeDecode = hasResidentSnapshot
                && hasReusableArtifact
                && !configuration.enabledBlocklistIDs.isEmpty
                && self.isCurrentSnapshotReloadGeneration(generation)
            if freedResidentBeforeDecode {
                self.replaceSnapshot(
                    FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset),
                    identity: nil,
                    generation: generation
                )
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-failclosed-before-decode", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                #endif
            }

            guard let loaded = await self.loadCompiledSnapshot(configuration: configuration, generation: generation) else {
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    #if DEBUG || LAVA_QA_TOOLS
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-skipped-stale-missing", details: [
                        "generation": "\(generation)",
                        "reason": reason
                    ])
                    loadSpan.end(details: ["status": "stale-missing"])
                    #endif
                    return
                }

                // The new snapshot could not be built. If we still hold a real FILTERING
                // resident (we did NOT free it above), KEEP it serving — a transient build
                // failure (e.g. a stale-pinned-hash refresh) must degrade to "keep last-known-
                // good", never to fail-closed + a self-reconnect loop. The resident stays
                // healthy, so clear the snapshot-unavailable marker. (hasResidentSnapshot/
                // freedResidentBeforeDecode are read pre-await but the generation guard above
                // already rejected any reload that committed a newer snapshot meanwhile, so
                // they still describe the live resident here.)
                //
                // We must NOT keep a pass-through resident: a non-nil identity also covers the
                // permissive snapshot built for an empty config. If the user just enabled a
                // blocklist (new config non-empty) and that compile failed, keeping the
                // pass-through would leave protection connected but serving NO filtering — a
                // silent fail-OPEN. So require the resident to be a genuine filtering snapshot;
                // otherwise fall through and fail CLOSED below.
                if hasResidentSnapshot && !freedResidentBeforeDecode && self.currentResidentSnapshotHasEnabledFilters() {
                    self.clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration: generation)
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-reload-failed-keeping-resident", details: [
                        "generation": "\(generation)",
                        "reason": reason
                    ])
                    #if DEBUG || LAVA_QA_TOOLS
                    loadSpan.end(details: ["status": "kept-resident"])
                    #endif
                    return
                }

                // No resident to fall back on (tunnel start), or we already freed it: fail
                // closed. Mark it snapshot-unavailable so the DNS smoke-probe failure this
                // block-all causes does NOT escalate to a self-reconnect restart loop —
                // restarting cannot rebuild a snapshot the config can't compile.
                var didCommitFailClosed = false
                if !configuration.enabledBlocklistIDs.isEmpty {
                    let failClosedSnapshot = FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)
                    let wasFailClosedBeforeBuildFailure = self.isResidentFailClosedDueToUnavailableSnapshot()
                    didCommitFailClosed = self.replaceSnapshot(
                        failClosedSnapshot,
                        failClosedDueToUnavailableSnapshot: true,
                        generation: generation
                    )
                    // Commit-landed AND transition-gated, like the over-budget site.
                    if didCommitFailClosed, !wasFailClosedBeforeBuildFailure {
                        Self.recordIncident(.failClosedEntered, reason: "snapshot-unavailable")
                    }
                    self.dnsStateQueue.async { [weak self] in
                        guard let self, self.isCurrentSnapshotReloadGeneration(generation) else {
                            return
                        }

                        self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                    }
                } else {
                    // Filters disabled (pass-through resident, not a fail-closed): clear any
                    // stale snapshot-unavailable marker so a later genuine DNS wedge can still
                    // self-reconnect. Generation-gated so a stale reload can't erase a newer
                    // reload's fail-closed marker.
                    self.clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration: generation)
                }

                if didCommitFailClosed {
                    self.failTransientBootstrapDNSWait(reason: "snapshot-unavailable-\(reason)")
                }
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-missing", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                #if DEBUG || LAVA_QA_TOOLS
                loadSpan.end(details: [
                    "status": configuration.enabledBlocklistIDs.isEmpty ? "missing" : "fail-closed"
                ])
                #endif
                return
            }

            guard self.isCurrentSnapshotReloadGeneration(generation) else {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-skipped-stale", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                loadSpan.end(details: ["status": "stale"])
                #endif
                return
            }

            let runtimeSnapshot = ResolverAdjustedRuntimeSnapshot(
                base: loaded.snapshot,
                resolver: configuration.resolverPreset
            )
            let runtimePolicySnapshot = ResolverAdjustedRuntimeSnapshot(
                base: loaded.snapshot,
                resolver: configuration.resolverPreset
            )
            self.dnsStateQueue.sync {
                // Generation-gate like every other dnsStateQueue access in this method (and like
                // replaceSnapshot below): a stale prior-lifecycle load must not refresh the
                // configuration bookkeeping — those markers belong to the current lifecycle's
                // loadInitialSharedState, which now also writes them on this queue.
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    return
                }
                self.refreshConfigurationIfNeeded(force: true)
            }
            // A real snapshot is now resident; replaceSnapshot clears the snapshot-
            // unavailable marker atomically (default false) so a genuine DNS wedge later
            // can still escalate to self-reconnect.
            let exitsFailClosed = self.isResidentFailClosedDueToUnavailableSnapshot()
            let didCommitRealSnapshot = self.replaceSnapshot(
                runtimeSnapshot,
                protectionPolicySnapshot: runtimePolicySnapshot,
                identity: loaded.identity,
                residentHasEnabledFilters: !configuration.enabledBlocklistIDs.isEmpty,
                generation: generation
            )
            if exitsFailClosed, didCommitRealSnapshot {
                // The marker-backed fail-closed window (over-budget / unbuildable) just
                // ended with a real snapshot commit. (The transient bootstrap window keeps
                // its marker false by design, so its exit is not separately recorded: a
                // SERVED transient window's serve-path record is bounded by this commit's
                // loadSnapshot-loaded debug-log line, which ships in reports — pairing it
                // here would need a cross-queue served-this-window latch on the reload
                // commit path for no added diagnostic value.)
                Self.recordIncident(.failClosedExited)
            }

            // Adopted a full snapshot ⇒ advance the Focus config-poll watermark (LAV-100 Phase 4 P4d).
            self.advanceFocusConfigurationWatermark(
                toAdoptedGeneration: configuration.configurationGeneration,
                ifCurrentReloadGeneration: generation
            )

            let duration = Date().timeIntervalSince(startedAt)
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-loaded", details: [
                "generation": "\(generation)",
                "reason": reason,
                "durationMs": "\(Int((duration * 1_000).rounded()))",
                "blockRuleCount": "\(runtimeSnapshot.blockRuleCount)",
                "allowRuleCount": "\(runtimeSnapshot.allowRuleCount)",
                "guardrailRuleCount": "\(runtimeSnapshot.guardrailRuleCount)",
                "footprintMB": Self.currentMemoryFootprintMB(),
                "resolver": configuration.resolverDiagnosticDisplayName
            ])
            #if DEBUG || LAVA_QA_TOOLS
            loadSpan.end(details: [
                "status": "loaded",
                "blockRuleCount": "\(runtimeSnapshot.blockRuleCount)",
                "footprintMB": Self.currentMemoryFootprintMB()
            ])
            #endif

            self.dnsStateQueue.async { [weak self] in
                guard let self else {
                    return
                }
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    return
                }

                self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                self.drainTransientBootstrapDNSWait(reason: "snapshot-loaded-\(reason)")
                self.refreshConfigurationIfNeeded(force: true)
                self.applyDiagnosticsControlIfNeeded(force: true)
                self.scheduleProtectionPauseResumeIfNeeded(reason: "snapshot-loaded-\(reason)")
                if self.diagnosticsPersistence.isDirty {
                    self.persistDiagnosticsIfNeeded(force: true)
                }
            }
        }
    }

    // MARK: - Temporary protection pause / resume

    private func scheduleProtectionPauseResumeIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleProtectionPauseResumeIfNeeded(reason: reason)
            }
            return
        }

        cancelProtectionPauseResumeTimer()
        guard let until = currentTemporaryProtectionPauseUntil() else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: dnsStateQueue)
        timer.schedule(deadline: .now() + max(0, until.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            self?.resumeExpiredTemporaryProtectionPauseIfNeeded()
        }
        protectionPauseResumeTimer = timer
        timer.resume()
    }

    private func cancelProtectionPauseResumeTimer() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelProtectionPauseResumeTimer()
            }
            return
        }

        protectionPauseResumeTimer?.cancel()
        protectionPauseResumeTimer = nil
    }

    private func resumeExpiredTemporaryProtectionPauseIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.resumeExpiredTemporaryProtectionPauseIfNeeded()
            }
            return
        }

        guard let until = currentTemporaryProtectionPauseUntil() else {
            cancelProtectionPauseResumeTimer()
            return
        }

        guard Date() >= until else {
            scheduleProtectionPauseResumeIfNeeded(reason: "pause-not-expired")
            return
        }

        protectionPauseResumeTimer = nil
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)
        lastAppliedTemporaryProtectionPauseIsActive = false
        updateLiveActivitiesAfterTemporaryProtectionPauseExpired()
        // No DNS runtime reset or snapshot reload on expiry: the loaded snapshot
        // is identity-unchanged, pause-era cache entries expire with the pause
        // window, and pending forwards re-check policy at completion.
    }

    private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired() {
        Task {
            let defaults = LavaSecAppGroup.sharedDefaults
            let state = LavaActivityAttributes.ContentState(
                protectionState: .on,
                resumeDate: nil,
                pauseRequiresAuthentication: SecurityProtectedSurfaceStorage.isProtected(
                    .protectionPause,
                    defaults: defaults
                ),
                shieldStyle: GuardianShieldStyle(
                    rawValue: defaults.string(forKey: LavaSecAppGroup.customizationLavaGuardLookDefaultsKey) ?? ""
                ) ?? .original,
                pauseMinutes: LiveActivityPausePreference.minutes(
                    from: ProtectionUserDefaultsStorage(defaults: defaults)
                )
            )
            let content = ActivityContent(state: state, staleDate: nil)
            let activities = Activity<LavaActivityAttributes>.activities

            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "pause-expired-live-activity-update", details: [
                "count": String(activities.count)
            ])
            #endif

            for activity in activities {
                // Re-verify before EACH update, co-located with activity.update: this ON publish
                // runs in an unstructured, unversioned ActivityKit Task (unlike the command
                // service's revision-guarded path), and each prior `await` in this loop can suspend
                // long enough for a new pause to be written — so a single pre-loop check would let
                // a stale `.on` reach the REMAINING activities and strand the Dynamic Island on
                // while the store/tunnel are paused. Any active pause → stop; leave the Live
                // Activity to that pause's own update (Codex #208).
                guard (try? protectionPauseStore.currentPauseState()) == nil else {
                    return
                }
                await activity.update(content)
            }
        }
    }

    private func isTemporaryProtectionPauseActive(
        now: Date = Date(),
        synchronizesDefaults: Bool = true
    ) -> Bool {
        guard let pauseUntil = currentTemporaryProtectionPauseUntil(synchronizesDefaults: synchronizesDefaults) else {
            return false
        }

        // UX-2 (Codex #208): an over-cap pausedUntil on the DNS hot path is a stale cached
        // value from before a backward wall-clock step — the 1s refresh gate wedges because
        // `now - lastRefresh` stays negative (< the interval) until the clock catches up, so
        // the store is never re-read. FORCE a store refresh: storedPauseState() compare-and-
        // discards the over-cap keys, and the refresh's vanished-pause detection reconciles
        // protection to ON (clears the applied flag + republishes the Live Activity). Then this
        // query is not paused. Only hiding it here would (a) let the same value re-activate for
        // its final ~cap window once wall time catches up, and (b) leave the Dynamic Island on
        // paused while filtering is on. One-shot: the refresh caches nil, so subsequent queries
        // take the fast not-paused path.
        if pauseUntil.timeIntervalSince(now) > ProtectionPauseStore.maxPauseDuration {
            _ = refreshTemporaryProtectionPauseState(synchronizesDefaults: synchronizesDefaults, now: now)
            return false
        }

        return pauseUntil > now
    }

    private func currentTemporaryProtectionPauseUntil(synchronizesDefaults: Bool = true) -> Date? {
        let now = Date()
        if synchronizesDefaults {
            return refreshTemporaryProtectionPauseState(synchronizesDefaults: true, now: now)
        }

        let shouldRefresh = protectionPauseStateQueue.sync {
            let sinceLastRefresh = now.timeIntervalSince(lastProtectionPauseStateRefreshAt)
            // A NEGATIVE interval = the wall clock stepped BACKWARD since the last refresh. Force
            // a store read so storedPauseState() compare-and-discards a now-over-cap pausedUntil
            // EVEN WHEN THE CACHE IS nil (an intent-written pause the tunnel never learned via a
            // reload-protection-pause message) — otherwise the over-cap keys survive unread and
            // re-activate once the clock catches up to within the cap of that date, turning
            // filtering off for the final pause window (UX-2, Codex #208). One-shot: the refresh
            // sets lastProtectionPauseStateRefreshAt = now, so the next query sees no backward step.
            return sinceLastRefresh >= protectionPauseStateRefreshInterval || sinceLastRefresh < 0
        }
        if shouldRefresh {
            return refreshTemporaryProtectionPauseState(synchronizesDefaults: true, now: now)
        }

        return protectionPauseStateQueue.sync {
            cachedTemporaryProtectionPauseUntil
        }
    }

    private func refreshTemporaryProtectionPauseState(
        synchronizesDefaults: Bool = true,
        now: Date = Date()
    ) -> Date? {
        // Read the store AND swap the cache under the SAME serialization point (Codex #208
        // post-merge): with the read outside this sync, two overlapping refreshes can interleave —
        // an older refresh reads a non-nil pausedUntil, a newer refresh caches nil + reconciles ON,
        // then the older refresh enters the sync and writes its STALE pause back into the cache, so
        // DNS treats protection as paused until the next refresh. Reading inside the sync means a
        // delayed refresh re-reads the CURRENT store when it finally acquires the queue, so a
        // vanished pause can never be re-cached.
        //
        // The swap also detects a pause that VANISHED — a cached pause the store no longer returns
        // because storedPauseState() compare-and-discarded an over-cap value (backward clock / corrupt
        // write) or another process cleared it. The transition (previous non-nil → now nil) is the
        // SINGLE-SHOT signal, so whichever refresh performs it reconciles the published state to ON.
        // Expired-but-in-window pauses are returned non-nil by the store, so they don't vanish here;
        // the resume timer still owns expiry.
        var pauseVanished = false
        var clampedCappedPause = false
        let pauseUntil: Date? = protectionPauseStateQueue.sync {
            let storedRead = readTemporaryProtectionPauseUntilFromDefaults(
                synchronizesDefaults: synchronizesDefaults
            )
            let previous = cachedTemporaryProtectionPauseUntil
            cachedTemporaryProtectionPauseUntil = storedRead.pauseUntil
            lastProtectionPauseStateRefreshAt = now
            pauseVanished = previous != nil && storedRead.pauseUntil == nil
            clampedCappedPause = storedRead.clampedCappedPause
            return storedRead.pauseUntil
        }
        // Reconcile ALSO when the store just CLAMPED an over-cap pause to nil, even if the cache
        // held no prior pause (previous == nil → no vanish transition). That is the case for a
        // pause written by the Live Activity intent that the tunnel never learned (the intent
        // publishes .paused via LavaProtectionCommandService but sends no reload message): the
        // store discard defuses the reactivation landmine, and this reconcile republishes ON so
        // ActivityKit doesn't stay paused while filtering is back on (Codex #208). Discarding the
        // keys makes it one-shot — the next read finds no keys and clamps nothing.
        if pauseVanished || clampedCappedPause {
            reconcileProtectionOnAfterVanishedTemporaryPause()
        }
        return pauseUntil
    }

    // Republish protection-ON after a pause vanished from the store (capped-discarded, or cleared
    // by another process) so the Dynamic Island doesn't stay on paused with a stale resume date
    // while filtering is back on (Codex #208). dnsStateQueue-confined for the applied flag; the
    // vanish transition in refreshTemporaryProtectionPauseState is the single-shot guard, so this
    // fires even for an intent-initiated pause the tunnel never marked applied (learned via the
    // refresh path, so lastApplied stays false while ActivityKit shows paused).
    private func reconcileProtectionOnAfterVanishedTemporaryPause() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.reconcileProtectionOnAfterVanishedTemporaryPause()
            }
            return
        }
        // Re-read the store on this dnsStateQueue hop: the reconcile was enqueued async, so a NEW
        // pause the user started in the meantime must not be clobbered by this now-stale
        // unconditional ON. If a current pause exists, leave it — its own .paused update stands,
        // and the normal apply path marks it applied (symmetric to the coordinator's .paused
        // re-verification, Codex #208).
        if (try? protectionPauseStore.currentPauseState()) != nil {
            return
        }
        lastAppliedTemporaryProtectionPauseIsActive = false
        updateLiveActivitiesAfterTemporaryProtectionPauseExpired()
    }

    private func cacheTemporaryProtectionPauseUntil(_ pauseUntil: Date?, refreshedAt: Date = Date()) {
        protectionPauseStateQueue.sync {
            cachedTemporaryProtectionPauseUntil = pauseUntil
            lastProtectionPauseStateRefreshAt = refreshedAt
        }
    }

    // synchronizesDefaults now only selects forced-refresh vs cached reads upstream;
    // cfprefsd already serves current app-group values cross-process, and flushing
    // here ran on the DNS hot path up to once per second. The store applies the
    // session binding (pauseSessionID == activeSessionID) and deliberately
    // returns expired pauses so the expiry timer can observe and clear them.
    private func readTemporaryProtectionPauseUntilFromDefaults(
        synchronizesDefaults: Bool
    ) -> (pauseUntil: Date?, clampedCappedPause: Bool) {
        guard let read = try? protectionPauseStore.storedPauseStateApplyingSanityCap() else {
            return (nil, false)
        }
        return (read.state?.pausedUntil, read.clampedCappedPause)
    }

    private func beginFreshProtectionVPNSession(reason: String) {
        let sessionID = (try? protectionSessionStore.beginFreshSession()) ?? ""
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-begin", details: [
            "reason": reason,
            "sessionID": sessionID
        ])
        #endif
    }

    private func endProtectionVPNSession(reason: String) {
        _ = try? protectionSessionStore.clearActiveSessionID()
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-end", details: [
            "reason": reason
        ])
        #endif
    }

    private var protectionPauseDefaults: UserDefaults {
        LavaSecAppGroup.sharedDefaults
    }

    // Single source of truth for session and pause state, shared with the app
    // and the intents process via the same app-group keys.
    private lazy var protectionSessionStore = ProtectionSessionStore(
        storage: ProtectionUserDefaultsStorage(defaults: protectionPauseDefaults),
        lock: ProtectionNSLock()
    )

    private lazy var protectionPauseStore = ProtectionPauseStore(
        storage: ProtectionUserDefaultsStorage(defaults: protectionPauseDefaults),
        lock: ProtectionNSLock()
    )

    @discardableResult
    // MARK: - Resident snapshot state & DNS runtime resets

    private func replaceSnapshot(
        _ newSnapshot: any FilterRuntimeSnapshot,
        protectionPolicySnapshot newProtectionPolicySnapshot: (any FilterRuntimeSnapshot)? = nil,
        identity newIdentity: PreparedFilterSnapshotIdentity? = nil,
        failClosedDueToUnavailableSnapshot: Bool = false,
        residentHasEnabledFilters: Bool = false,
        generation: UInt64
    ) -> Bool {
        // The reload-generation token (`snapshotReloadGeneration`) lives on
        // dnsStateQueue; the snapshot pointer lives on snapshotQueue. Gate the commit
        // on the LIVE token while holding dnsStateQueue, then swap the pointer under
        // snapshotQueue. Comparing against the live token (not merely a "highest
        // committed" high-water mark) rejects a stale load as soon as a newer reload
        // has been *requested* — even before that newer load has committed anything —
        // so a slow stale decode can't briefly reinstall an older/permissive snapshot
        // for the new configuration. Holding dnsStateQueue across the read+swap closes
        // the cross-queue gap (the token can only change on dnsStateQueue). `==` still
        // admits the one load that legitimately commits twice at the same generation
        // (fail-closed before decode, then the real snapshot) as long as no newer
        // reload has been requested in between. Ordering is always
        // dnsStateQueue -> snapshotQueue (snapshotQueue is a leaf lock on the decision
        // hot path and never reaches back to dnsStateQueue), so this can't deadlock.
        // Reported back so OBSERVABILITY at the call sites (the incident ledger's
        // fail-closed records) can key on whether the commit actually LANDED — a
        // superseded reload's no-op must not record an incident that was never served.
        var didCommit = false
        let applyIfStillCurrent: () -> Void = { [self] in
            guard generation == snapshotReloadGeneration else {
                return
            }
            snapshotQueue.sync {
                snapshot = newSnapshot
                protectionPolicySnapshot = newProtectionPolicySnapshot ?? newSnapshot
                residentSnapshotIdentity = newIdentity
                // Committed atomically with the snapshot under the SAME generation gate, so
                // the markers can never disagree with the resident (a stale-generation commit
                // that doesn't apply also doesn't flip the flags).
                residentFailClosedDueToUnavailableSnapshot = failClosedDueToUnavailableSnapshot
                residentSnapshotHasEnabledFilters = residentHasEnabledFilters
            }
            didCommit = true
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            applyIfStillCurrent()
        } else {
            dnsStateQueue.sync(execute: applyIfStillCurrent)
        }
        return didCommit
    }

    private func currentResidentSnapshotIdentity() -> PreparedFilterSnapshotIdentity? {
        snapshotQueue.sync { residentSnapshotIdentity }
    }

    // Generation-gated clear of the snapshot-unavailable marker. The keep-resident and
    // filters-disabled reload branches run on a detached task OUTSIDE replaceSnapshot's
    // generation gate, so an UNGATED clear here could erase a newer reload's true marker
    // (committed via replaceSnapshot) after this older reload was already superseded —
    // re-arming the self-reconnect loop this change suppresses. Gate the clear on the live
    // token under the same dnsStateQueue -> snapshotQueue ordering as replaceSnapshot so a
    // stale reload can never clear a fresher commit's marker.
    private func clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration generation: UInt64) {
        let applyIfStillCurrent: () -> Void = { [self] in
            guard generation == snapshotReloadGeneration else {
                return
            }
            snapshotQueue.sync { residentFailClosedDueToUnavailableSnapshot = false }
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            applyIfStillCurrent()
        } else {
            dnsStateQueue.sync(execute: applyIfStillCurrent)
        }
    }

    private func isResidentFailClosedDueToUnavailableSnapshot() -> Bool {
        snapshotQueue.sync { residentFailClosedDueToUnavailableSnapshot }
    }

    private func currentResidentSnapshotHasEnabledFilters() -> Bool {
        snapshotQueue.sync { residentSnapshotHasEnabledFilters }
    }

    // Cheap header-only budget check (no rule-table decode). Returns the total
    // filter-rule count when the on-disk artifact exceeds the on-device memory
    // budget, else nil. Used to refuse decoding an artifact that would jetsam
    // the extension.
    private func compactSnapshotRuleCountExceedingBudget(configuration: AppConfiguration) -> Int? {
        guard let summary = readCompactSnapshotSummary(configuration: configuration) else {
            return nil
        }

        let totalRuleCount = summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount
        return FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: totalRuleCount) ? totalRuleCount : nil
    }

    // Reads only the on-disk compact artifact header (no rule-table decode) and
    // returns true when decoding it would reproduce the resident snapshot for
    // the current configuration — i.e. the reload is a no-op and the
    // multi-megabyte decode (and its 2x-resident memory peak) can be skipped.
    private func residentSnapshotSatisfiesReload(configuration: AppConfiguration) -> Bool {
        guard let residentIdentity = currentResidentSnapshotIdentity() else {
            return false
        }

        // A resident snapshot compiled from EXACTLY the inputs this reload would compile
        // from (same configuration inputs + same cached-catalog source versions/hashes)
        // already satisfies the reload even when NO on-disk artifact is reusable — the
        // stale-store state UR-48 exposed, where the artifact store lags the cached
        // catalog and the tunnel compiled in-extension. Identity is stamped from
        // (configuration, cachedCatalog) at compile, so identical inputs reproduce the
        // resident byte-for-byte; without this gate every appMessage reload repeats the
        // same streaming compile (observed 6.9 s / 356 k rules on device) and its
        // compile-peak for an identical result. A fail-closed resident commits with a
        // nil identity and a last-known-good resident carries stale source hashes, so
        // neither can satisfy this gate and recovery reloads still run.
        if !configuration.enabledBlocklistIDs.isEmpty,
           residentIdentity.resolverTransport == configuration.resolverPreset.transport,
           let cachedCatalog = loadCachedCatalogMetadata(),
           residentIdentity.hasSameSnapshotInputs(
               as: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: cachedCatalog)
           ) {
            return true
        }

        guard let summary = readCompactSnapshotSummary(configuration: configuration) else {
            return false
        }

        return summary.canReuseForProtectionStartup(
            configuration: configuration,
            cachedCatalog: loadCachedCatalogMetadata()
        ) && summary.identity.hasSameSnapshotInputs(as: residentIdentity)
    }

    /// Resolve the artifact store the tunnel should READ from: the pointer-named
    /// versioned directory if a pointer is published and its dir exists, else the
    /// legacy root. `readableStore()` falls back to root for no-pointer / first launch
    /// / a whole-dir GC (re-resolved next pass). The app no longer dual-writes root:
    /// `persistArtifacts` writes only versioned dirs + the pointer (test-asserted), and the
    /// legacy root is deliberately left unswept — so under the current build the root store
    /// only ages, and a FRESH root can only come from a rollback to an old root-writing
    /// build. The root retry stays correct either way: every root read is identity-gated
    /// against the live config.
    /// `loadCompiledSnapshot` additionally retries the root store in the SAME pass when
    /// the resolved store misses (rejected identity, or a nil read from a dir GC'd in
    /// the post-resolve / pre-open window). Resolve-once is intra-`loadCompiledSnapshot`;
    /// the reload gates resolve independently but `readCompactSnapshotSummary` applies
    /// the same [pointer-resolved, root] fallback and returns only a summary reusable
    /// for the live config — so the no-op / over-budget gates never act on a stale
    /// shadow (a cross-gate generation skew costs at most a redundant decode, never a
    /// wrong fail-closed or torn rules).
    ///
    /// Device-gated (LAV-90 Task 6) GC-unlink safety has two distinct arguments:
    /// - compact (`.mappedIfSafe`): the mapping pins the file inode past an unlink (no
    ///   SIGBUS), and content-addressed immutability means a published dir is never
    ///   rewritten/truncated in place — an in-place `ftruncate` of a mapped file is the
    ///   only Darwin op that faults mapped pages past EOF, and it cannot happen here.
    /// - prepared (eager `Data(contentsOf:)`): the `open()` fd pins the inode so a
    ///   mid-read unlink completes against the orphaned inode; a pre-open unlink ENOENTs
    ///   to nil and retries root / fails closed.
    /// The mmap-survives-unlink assumption (and the real flap rate under burst) is still
    /// pending on-device validation with a rapid-publish-burst stress against a MAP-LARGE
    /// artifact. (The root dual-write this note originally gated is already dropped on the
    /// writer side; the validation matters on its own for the pointer-dir read path.)
    private func readableArtifactStore() -> FilterArtifactStore? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }
        return FilterArtifactStore(directoryURL: containerURL).readableStore()
    }

    private func readCompactSnapshotSummary(configuration: AppConfiguration) -> CompactFilterSnapshotSummary? {
        let cachedCatalog = loadCachedCatalogMetadata()

        var stores: [FilterArtifactStore] = []
        if let resolved = readableArtifactStore() {
            stores.append(resolved)
        }
        if let containerURL = LavaSecAppGroup.containerURL {
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            if stores.first?.directoryURL != rootStore.directoryURL {
                stores.append(rootStore)
            }
        }
        // Keep this reader consistent with loadCompiledSnapshot's candidate set: the
        // no-op and over-budget gates must judge the same artifact the load would
        // actually adopt, including the tunnel's own retained compile.
        if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {
            stores.append(tunnelCompiledStore)
        }

        // Return the summary the tunnel would actually load for this configuration: the
        // first reusable one across [pointer-resolved, root, tunnel-compiled]. A stale shadow (a pointer
        // lagging root, or a generation that no longer covers the config) must NOT drive
        // the reload no-op / over-budget gates — otherwise a partial-publish or rollback
        // could fail-closed on a stale over-budget artifact while root is fresh and fine.
        for store in stores {
            guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]),
                  let summary = try? CompactFilterSnapshot.readSummary(from: data)
            else {
                continue
            }
            if summary.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: cachedCatalog) {
                return summary
            }
        }
        return nil
    }

    private func replaceSnapshotResolver(_ resolver: DNSResolverPreset) {
        snapshotQueue.sync {
            snapshot = ResolverAdjustedRuntimeSnapshot(base: snapshot, resolver: resolver)
            protectionPolicySnapshot = ResolverAdjustedRuntimeSnapshot(base: protectionPolicySnapshot, resolver: resolver)
        }
    }

    private func refreshDNSRuntimeAfterSnapshotOrConfigurationChange() {
        let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
        if let activeResolverRuntimeIdentifier,
           activeResolverRuntimeIdentifier != resolverIdentifier {
            resetResolverRuntimeStateOnDNSQueueIfNeeded(identifier: resolverIdentifier)
            return
        }

        resetDNSRuntimeForProtectionPolicyChange(reason: "snapshot-or-configuration-changed")
    }

    private func resetDNSRuntimeForProtectionPolicyChange(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.resetDNSRuntimeForProtectionPolicyChange(reason: reason)
            }
            return
        }

        resolverRuntimeGeneration += 1
        let pendingResponses = inFlightQueryCoalescer.drainAll()
        dnsResponseCache.removeAll()
        clearEndpointHostnameNormalizationCache()
        // NRG-3a: probe-equivalent evidence never survives a runtime reset — the new
        // runtime (wake, config change, identity change, fallback flip) re-proves with
        // a real probe, exactly like the pre-skip behavior.
        lastAcceptedPrimaryEvidenceAt = nil
        health.lastResolverRuntimeResetAt = Date()
        health.lastResolverRuntimeResetReason = reason
        health.resolverRuntimeResetCount += 1
        writeServerFailures(for: pendingResponses, reason: reason)
    }

    private func resetResolverRuntimeStateIfNeeded(identifier: String) {
        let pendingResponses = dnsStateQueue.sync {
            collectPendingResponsesAndResetResolverRuntime(
                identifier: identifier,
                reason: "resolver-configuration-changed"
            )
        }

        writeServerFailures(for: pendingResponses, reason: "resolver-configuration-changed")
    }

    private func resetResolverRuntimeStateOnDNSQueueIfNeeded(identifier: String) {
        let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
            identifier: identifier,
            reason: "resolver-configuration-changed"
        )
        writeServerFailures(for: pendingResponses, reason: "resolver-configuration-changed")
    }

    private func resetResolverRuntimeForTunnelLifecycle(reason: String) {
        dnsStateQueue.sync {
            activeResolverRuntimeIdentifier = nil
            resolverRuntimeGeneration += 1
            dnsResponseCache.removeAll()
            clearEndpointHostnameNormalizationCache()
            _ = inFlightQueryCoalescer.drainAll()
            resolverBackoffStateQueue.sync {
                resolverBackoffPolicy.reset()
            }
        }

        dohResolver.resetSession()
        dotResolver.resetConnections()
        doqResolver.resetConnections()
    }

    private func resetResolverTransientState() {
        dohResolver.resetSession()
        dotResolver.resetConnections()
        doqResolver.resetConnections()
    }

    private func collectPendingResponsesAndResetResolverRuntime(
        identifier: String,
        reason: String,
        force: Bool = false
    ) -> [PendingDNSResponse] {
        guard force || activeResolverRuntimeIdentifier != identifier else {
            return []
        }

        // Don't let a stale per-query identifier clobber a newer runtime. The non-forced
        // (per-query, lazy) reset carries the resolver identifier `handle` captured when it
        // classified the packet, then reused by `forward`. If a concurrent authoritative reload
        // (snapshot/config change, fallback flip, network-path change) has since advanced BOTH
        // `appConfiguration` and the active runtime to a different resolver, honoring the captured
        // identifier here would flip the active runtime BACK to the resolver the config has already
        // moved away from — draining the new runtime's in-flight queries and clearing its cache,
        // only for the next query to flip it forward again. Every forced reset and the authoritative
        // apply path (`refreshDNSRuntimeAfterSnapshotOrConfigurationChange`) pass the CURRENT
        // identifier, so this drops ONLY the stale lazy case: leave the current runtime in place —
        // the racing query then fails its `isActiveResolverRuntime` gate and is retried under the
        // current resolver. dnsStateQueue-confined; the plan rebuild runs only on this rare
        // active-differs path, never the steady-state no-op returned above.
        if !force, identifier != currentResolverRuntimeConfiguration().cacheIdentifier {
            return []
        }

        let previousIdentifier = activeResolverRuntimeIdentifier
        let isInitialActivation = previousIdentifier == nil
        activeResolverRuntimeIdentifier = identifier
        // Track the PRIMARY-only identity separately: the full `identifier` (the runtime cache key)
        // also folds in fallback / encrypted-fallback / fallback-mode components, which change on
        // fallback-only resets that must NOT advance the context baseline or clear the rejected streak.
        // Taken MODE-INSENSITIVELY (COH-1): with device-DNS-fallback MODE active, the plain
        // `primaryCacheIdentifier` reflects the *effective* transport (`.deviceDNS`), so a mode flip
        // on an unchanged encrypted primary would read as a primary-identity change here — advancing
        // `lastResolverIdentityChangeAt` and zeroing the rejected streak below (the second DNS-1
        // channel this closes). `ignoresDeviceDNSFallbackMode: true` pins it to the configured upstream.
        let previousPrimaryIdentifier = activeResolverPrimaryIdentifier
        let currentPrimaryIdentifier = currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true).primaryCacheIdentifier
        activeResolverPrimaryIdentifier = currentPrimaryIdentifier
        resolverRuntimeGeneration += 1
        let pendingResponses = inFlightQueryCoalescer.drainAll()
        dnsResponseCache.removeAll()
        clearEndpointHostnameNormalizationCache()
        // NRG-3a: probe-equivalent evidence never survives a runtime reset — the new
        // runtime (wake, config change, identity change, fallback flip) re-proves with
        // a real probe, exactly like the pre-skip behavior.
        lastAcceptedPrimaryEvidenceAt = nil
        // The negotiated-protocol observation belongs to the previous
        // resolver/network; the new runtime re-observes before claiming DoH3.
        health.lastDoHHTTPVersion = nil
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.reset()
        }
        resetResolverTransientState()
        prewarmResolverBootstrapIfNeeded()
        if force || !isInitialActivation {
            health.lastResolverRuntimeResetAt = Date()
            health.lastResolverRuntimeResetReason = reason
            health.resolverRuntimeResetCount += 1
            // A resolver-runtime reset opens a fresh fallback episode (mirrors
            // resetFailureAndFallbackStateForRecovery for the network-change path): drop the
            // episode-scoped carried-failure streak and the stale failure reason so they can't
            // gate the NEW resolver's coverage assessment. The identity-scoped rejected streak is
            // NOT cleared on a SAME-resolver reset — it is LAV-87 hijack evidence that must survive
            // network-flap churn — but IS cleared on a genuine identity change below.
            consecutiveCarriedQueryFailureCount = 0
            // A resolver-runtime reset opens a fresh fallback episode (per the comment
            // above), so the coalesced encrypted-fallback log marker is stale too — clear
            // it so the new runtime's first carried query logs rather than being throttled
            // by the previous runtime's marker.
            clearEncryptedFallbackLogThrottle(phase: "context-reset")
            health.lastFailureReason = nil
            // Invalidate the encrypted-fallback COVERAGE timestamp on ANY runtime reset. It proves
            // "the CURRENT encrypted fallback served a query recently", but a reset may have changed
            // the fallback itself (disabled it, or swapped its resolver) — and the PRIMARY-identity
            // branch below deliberately doesn't move the baseline for a fallback-only change, so
            // nothing else would invalidate it. Leaving it would let a just-disabled / unproven
            // fallback keep suppressing the reconnect via the OLD fallback's success. For non-fallback
            // resets this is redundant (the context baseline already lapses coverage) and harmless
            // (the next carried success through the active fallback re-stamps it).
            health.lastEncryptedFallbackSuccessAt = nil
            // Advance the DNS-health-context baseline ONLY on a genuine PRIMARY-resolver identity
            // change (a different upstream) — never on a forced same-resolver runtime reset
            // (recovery; snapshot-reload/pause go through resetDNSRuntimeForProtectionPolicyChange,
            // not here) NOR on a fallback-only change (encrypted-fallback resolver swap, device-DNS
            // fallback toggle) that leaves the primary unchanged. Keyed on the PRIMARY identity, not
            // the full `identifier`, so a benign fallback reset can't make an existing failed smoke
            // probe look pre-context and hide a still-wedged primary (smokeProbeContextBaseline reads
            // lastResolverIdentityChangeAt).
            if let previousPrimaryIdentifier, previousPrimaryIdentifier != currentPrimaryIdentifier {
                health.lastResolverIdentityChangeAt = Date()
                // The rejected-response streak is identity-scoped evidence about the PREVIOUS
                // resolver. Once we switch to a different upstream it is stale; left intact, the
                // coverage gate (which declines on ANY nonzero count) would force the NEW resolver
                // to `.needsReconnect` even with the fallback serving, until its own first rejection
                // re-scopes the streak. Clear it on the switch — the new resolver starts with no
                // pending rejection evidence and rebuilds its own streak if IT rejects. Safe for
                // LAV-87: a same-resolver network flap keeps the same cacheIdentifier, so this branch
                // does not fire and the streak survives the churn it is meant to.
                health.consecutiveRejectedSmokeResponseCount = 0
                health.rejectedSmokeResponseResolverIdentity = nil
            }
        }
        return pendingResponses
    }

    private func writeServerFailures(for pendingResponses: [PendingDNSResponse], reason: String? = nil) {
        if !pendingResponses.isEmpty, let reason {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "pending-dns-servfail", details: [
                "reason": reason,
                "pendingResponses": "\(pendingResponses.count)"
            ])
        }

        for pending in pendingResponses {
            guard let response = DNSResponseFactory.serverFailure(for: pending.request.dnsPayload) else {
                continue
            }

            writeDNSResponse(response, for: pending.request, protocolNumber: pending.protocolNumber)
        }
    }

    // MARK: - Filter decision

    private func filterDecision(for domain: String) -> FilterDecision {
        snapshotQueue.sync {
            snapshot.decision(for: domain)
        }
    }

    private func filterDecision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        snapshotQueue.sync {
            snapshot.decision(forNormalizedDomain: normalizedDomain)
        }
    }

    /// Decision + fail-closed reason read under the SAME snapshotQueue pass, so the reason
    /// can never describe a different resident snapshot than the one that made the decision:
    /// a queued reload commit can flip `residentFailClosedDueToUnavailableSnapshot` between
    /// the decision and any deferred read, mislabeling a snapshot-unavailable block as
    /// transient (or the reverse).
    private func filterDecisionCapturingFailClosedReason(
        forNormalizedDomain normalizedDomain: String
    ) -> (decision: FilterDecision, failClosedReason: String?) {
        snapshotQueue.sync {
            let decision = snapshot.decision(forNormalizedDomain: normalizedDomain)
            guard decision.reason == .protectionUnavailable else {
                return (decision, nil)
            }
            return (
                decision,
                residentFailClosedDueToUnavailableSnapshot
                    ? "snapshot-unavailable"
                    : "transient-protection-unavailable"
            )
        }
    }

    private func protectionPolicyDecision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        snapshotQueue.sync {
            protectionPolicySnapshot.decision(forNormalizedDomain: normalizedDomain)
        }
    }

    private func temporaryPauseMaximumAnswerTTL(forNormalizedDomain normalizedDomain: String) -> UInt32? {
        let decision = protectionPolicyDecision(forNormalizedDomain: normalizedDomain)
        return decision.action == .block ? pausedWouldBlockForwardTTL : nil
    }

    private func currentResolverPreset() -> DNSResolverPreset {
        snapshotQueue.sync {
            snapshot.resolver
        }
    }

    private func loadConfiguration() -> AppConfiguration? {
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL)
        else {
            return nil
        }

        return try? JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    // MARK: - Snapshot compile, artifact stores & fast-resume

    private func loadCompiledSnapshot(
        configuration: AppConfiguration,
        generation: UInt64
    ) async -> (snapshot: any FilterRuntimeSnapshot, identity: PreparedFilterSnapshotIdentity)? {
        let cachedCatalog = loadCachedCatalogMetadata()
        let expectedIdentity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: cachedCatalog
        )

        // Try the pointer-resolved (versioned) artifact set first, then the legacy
        // root set. A pointer that lags the root — a partially-failed publish that
        // wrote root but did not flip the pointer, a surviving current.json after
        // rolling back to a root-only build that rewrote root, or a versioned dir GC'd
        // in this pass's post-resolve/pre-open window — must NOT shadow the fresh root
        // copy: a miss (rejected identity, or a nil read from an evicted dir) retries
        // the root store before the in-extension recompile. Each store is read as a
        // single resolved unit, so compact + prepared within one store never mix
        // generations.
        var artifactStores: [(store: FilterArtifactStore, route: String)] = []
        if let containerURL = LavaSecAppGroup.containerURL {
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            if let resolved = readableArtifactStore() {
                let route = resolved.directoryURL == rootStore.directoryURL ? "root" : "resolved"
                artifactStores.append((store: resolved, route: route))
            }
            if artifactStores.first?.store.directoryURL != rootStore.directoryURL {
                artifactStores.append((store: rootStore, route: "root"))
            }
        }
        // The tunnel's own retained compile is the LAST candidate: identical identity/
        // budget gating to the app stores (reusableCompactSnapshot), it only wins when
        // the app-published stores miss — the stale-store state where the only
        // alternative is repeating the streaming compile. Being in this list also makes
        // it a last-known-good candidate for serveLastKnownGoodOrFailClosed, which is
        // deliberate: it is the user's own previously-compiled, config-exact rules, and
        // canServeAsLastKnownGood applies the same never-fail-open gates to it.
        if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {
            artifactStores.append((store: tunnelCompiledStore, route: "tunnel-compiled"))
        }

        for (artifactStore, route) in artifactStores {
            // Both reads gate (reuse + budget) BEFORE the multi-MB decode and re-validate
            // from consistent bytes, so a stale/over-budget artifact is never materialized
            // before the root fallback, and a concurrent atomic rewrite of the mutable
            // root store cannot slip a different generation past the header check.
            let compactResult = reusableCompactSnapshot(
                from: artifactStore,
                configuration: configuration,
                cachedCatalog: cachedCatalog
            )
            if let compactSnapshot = compactResult.snapshot {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-hit", details: [
                    "identity": compactSnapshot.identity.fingerprint,
                    "route": route
                ])
                return (compactSnapshot, compactSnapshot.identity)
            }

            let preparedResult = reusablePreparedSnapshot(
                from: artifactStore,
                configuration: configuration,
                cachedCatalog: cachedCatalog
            )
            if let preparedSnapshot = preparedResult.snapshot {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-prepared-hit", details: [
                    "identity": preparedSnapshot.identity.fingerprint,
                    "route": route
                ])
                return (preparedSnapshot.snapshot, preparedSnapshot.identity)
            }

            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-store-miss", details: [
                "route": route,
                "compactReason": compactResult.missReason ?? "unknown",
                "preparedReason": preparedResult.missReason ?? "unknown",
                "generation": "\(generation)"
            ])
        }

        let baseSnapshot = configuration.filterSnapshot()

        // Shared build-failure path. A fresh (re)compile could not be produced — most
        // often the rotating-upstream / stale-pinned-hash wedge, where the cached catalog
        // rotated past the on-disk artifact (so the strict reuse gate above missed) AND
        // the in-extension recompile throws checksumMismatch against the stale cached
        // source content. On a COLD start there is no in-memory resident to keep, so the
        // caller would otherwise fail CLOSED and clear protection to zero. Instead, serve
        // a config-matched last-known-good artifact (same enabled-list set / manual rules /
        // custom fingerprints / parser version — only the catalog/guardrail content hashes
        // are stale), returning its OWN stale identity so a later reload swaps in fresh
        // rules once the app republishes a buildable artifact. Falls through to the
        // empty-config pass-through, or nil (fail-closed) for a non-empty config with no
        // serviceable artifact.
        //
        // DISK FALLBACK IS COLD-START ONLY. On a live reload that still holds a healthy
        // FILTERING resident (the catalog rotated but the in-memory snapshot is fine), we
        // must NOT decode a disk artifact: returning nil lets loadSnapshotInBackground take
        // its existing keep-resident branch, which avoids the multi-MB decode and the
        // 2x-resident memory peak that could jetsam the extension on a near-budget snapshot.
        // When the caller freed the resident pre-decode its identity is already nil, so this
        // gate correctly falls through to the disk fallback (no resident left to keep) —
        // making it equivalent to the caller's `hasResidentSnapshot && !freedResidentBeforeDecode
        // && currentResidentSnapshotHasEnabledFilters()` keep condition.
        func serveLastKnownGoodOrFailClosed() -> (snapshot: any FilterRuntimeSnapshot, identity: PreparedFilterSnapshotIdentity)? {
            // ROOT guard for the superseded-fallback class (Codex #213): if this reload was already
            // superseded, DO NOT decode a multi-MB last-known-good. The stale generation's commit is
            // rejected anyway, and the decode can overlap the winning compile and recreate the peak
            // the gate prevents. Return nil so the caller re-checks the generation and bails cleanly
            // (loadSnapshot-skipped-stale-missing). Gating HERE covers EVERY fallback caller — missing
            // catalog, over-budget, and the compile-error catch — not only the compile-skip paths.
            guard self.isCurrentSnapshotReloadGeneration(generation) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-fallback-skipped-stale", details: [
                    "generation": "\(generation)"
                ])
                return nil
            }
            let hasKeepableFilteringResident = self.currentResidentSnapshotIdentity() != nil
                && self.currentResidentSnapshotHasEnabledFilters()
            if !hasKeepableFilteringResident, !configuration.enabledBlocklistIDs.isEmpty {
                for (artifactStore, route) in artifactStores {
                    if let lastGood = self.lastKnownGoodCompactSnapshot(
                        from: artifactStore,
                        configuration: configuration
                    ) {
                        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-last-known-good", details: [
                            "identity": lastGood.identity.fingerprint,
                            "route": route
                        ])
                        return (lastGood, lastGood.identity)
                    }
                }
            }
            return configuration.enabledBlocklistIDs.isEmpty ? (baseSnapshot, expectedIdentity) : nil
        }

        guard let catalogCacheURL else {
            return serveLastKnownGoodOrFailClosed()
        }

        // CON-3: skip a DOOMED compile. A newer reload only bumps the generation (it fences
        // the commit); without this the superseded compile still runs its full ~32 MiB peak.
        // Re-check the reload generation IMMEDIATELY before the compiler so a reload the app
        // (or the Focus poll) has already superseded never spends the peak. Return nil, NOT the
        // fallback (Codex #213): a superseded generation must not materialize a multi-MB
        // last-known-good decode that its own commit would discard — that decode can overlap the
        // winning compile and reintroduce the peak this gate prevents. The caller's `guard let
        // else` re-checks the generation and bails cleanly (loadSnapshot-skipped-stale-missing);
        // the winning generation's own compile commits the real snapshot.
        guard isCurrentSnapshotReloadGeneration(generation) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compile-skipped-stale", details: [
                "generation": "\(generation)"
            ])
            return nil
        }

        do {
            // NOTE: scratch from a jetsam-killed compile is swept ONCE at startTunnel, not
            // here — sweeping per-compile would race a concurrent reload's in-flight scratch.
            //
            // CON-3: run the compile behind snapshotCompileGate so at most one ~32 MiB peak is
            // resident at a time — two overlapping reloads (start + pull-to-refresh) would
            // otherwise peak ≈60 MiB in the 50 MB-limited NE process and jetsam the tunnel.
            // Only the compile is serialized (the cheap header reads above stay concurrent);
            // the gate holds exclusivity across the WHOLE await, unlike a bare actor.
            let compiled = try await snapshotCompileGate.run { [weak self] in
                // CON-3 (Codex #213): re-check the reload generation AFTER the gate grants exclusivity.
                // The pre-gate check only catches supersession BEFORE entering the gate; a reload that
                // queued behind an earlier compile can be superseded WHILE it waits its turn. Re-check
                // here so a now-doomed compile never spends its ~32 MiB peak (its commit would be
                // rejected anyway). isCurrentSnapshotReloadGeneration hops to dnsStateQueue, so it is
                // safe from this off-queue task context; the latest generation still passes and compiles.
                guard self?.isCurrentSnapshotReloadGeneration(generation) ?? false else {
                    throw SnapshotCompileSuperseded()
                }
                // Retain the compiled artifact at the tunnel-compiled path so the NEXT
                // cold start fast-resumes from this compile instead of repeating it (and
                // taking the transient fail-closed bootstrap window again). Best-effort
                // inside the compiler; a superseded compile may briefly retain older
                // inputs, which every reader rejects via the identity gate until the
                // winning compile atomically replaces the file.
                let compiledSnapshot = try await CachedFilterSnapshotCompiler(
                    cacheDirectoryURL: catalogCacheURL
                ).compile(
                    baseSnapshot: baseSnapshot,
                    configuration: configuration,
                    stampIdentity: expectedIdentity,
                    retainedArtifactURL: self?.tunnelCompiledArtifactStore?.compactSnapshotURL
                )
                // Post-compile re-check, STILL INSIDE the gate (Codex #213 P1): a reload can be
                // superseded WHILE this compile runs. Returning the result here would complete
                // `run` and RELEASE the gate, letting the next queued compile start while this stale
                // caller still holds its multi-MB compiled snapshot — the two overlap and recreate
                // the peak the gate exists to prevent. Re-check before returning so a mid-compile
                // supersession discards the result inside the gate (the next compile is still
                // waiting), not after release.
                guard self?.isCurrentSnapshotReloadGeneration(generation) ?? false else {
                    throw SnapshotCompileSuperseded()
                }
                return compiledSnapshot
            }
            // The streaming compile returns a MEMORY-MAPPED CompactFilterSnapshot (entries
            // resident ~9 B/rule, domain bytes paged from disk) — never a dirty union — so it
            // is gated by the compact device budget, the same ceiling the app's mapped artifact
            // uses (`maxFilterRuleCount`), NOT the dirty per-source/transient caps the compiler
            // already enforced and failed closed under. After the parserRulesVersion bump this
            // fallback is exactly what runs on the first post-upgrade start before the app
            // regenerates artifacts. Over budget → we must NOT resident-load it (jetsam), but a
            // same-config catalog rotation can make a FRESH compile over-budget while an older
            // compact artifact for the same config is still within budget — so route through the
            // last-known-good fallback (itself budget-gated, so it can only serve an in-budget
            // artifact) rather than clearing protection. Falls through to fail-closed if there
            // is none, so the app re-prepares.
            let compiledRuleCount = compiled.blockRuleCount + compiled.allowRuleCount + compiled.guardrailRuleCount
            if FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: compiledRuleCount) {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compiled-over-budget", details: [
                    "ruleCount": "\(compiledRuleCount)",
                    "maxRuleCount": "\(FilterSnapshotMemoryBudget.maxFilterRuleCount)"
                ])
                return serveLastKnownGoodOrFailClosed()
            }
            return (compiled, expectedIdentity)
        } catch is SnapshotCompileSuperseded {
            // A newer reload superseded this one while it waited in the compile gate — skipped the
            // peak. Return nil, NOT the fallback (Codex #213): after the gate wait the winning reload
            // is likely already compiling, so decoding a multi-MB last-known-good here (which this
            // stale generation's own commit would discard) can overlap that compile and reintroduce
            // the peak the gate exists to prevent. The caller re-checks the generation and bails
            // cleanly (loadSnapshot-skipped-stale-missing). Not an error.
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compile-skipped-stale-in-gate", details: [
                "generation": "\(generation)"
            ])
            return nil
        } catch {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-cache-compile-error", details: Self.errorDebugDetails(error))
            return serveLastKnownGoodOrFailClosed()
        }
    }

    /// Thrown inside the compile gate when a reload is superseded while awaiting its turn, so the
    /// doomed compile bails before spending its memory peak (CON-3, Codex #213). Sendable so it can
    /// cross the gate's `@Sendable` operation boundary.
    private struct SnapshotCompileSuperseded: Error {}

    // Reads a store's compact bytes ONCE and returns the decoded snapshot only when it
    // is reusable for `configuration` and within the rule budget — the gate and the
    // decode share the SAME bytes (`.mappedIfSafe` pins the inode), so a concurrent
    // atomic rewrite of the mutable root store cannot slip a different or over-budget
    // generation past the header check, and a stale/over-budget artifact is never
    // materialized before the root fallback.
    private func reusableCompactSnapshot(
        from store: FilterArtifactStore,
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?,
        syncDecodeRuleCap: Int? = nil
    ) -> (snapshot: CompactFilterSnapshot?, missReason: String?) {
        guard FileManager.default.fileExists(atPath: store.compactSnapshotURL.path) else {
            return (nil, "missing")
        }
        guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]) else {
            return (nil, "unreadable")
        }
        guard let summary = try? CompactFilterSnapshot.readSummary(from: data) else {
            return (nil, "invalid")
        }
        if let reuseRejection = compactReuseRejectionReason(
            summary: summary,
            configuration: configuration,
            cachedCatalog: cachedCatalog
        ) {
            return (nil, "reuse:\(reuseRejection)")
        }

        let ruleCount = summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount
        // AUTHORITATIVE sync-cap check, on the SAME mmapped bytes that will be decoded
        // (`.mappedIfSafe` pins the inode). Only the cold-start bootstrap passes a cap; the async
        // path passes nil. The bootstrap's cheap pre-gate is best-effort — an atomic republish of
        // the mutable root store between the pre-gate read and this read could otherwise slip an
        // over-cap (but in-budget) artifact into a synchronous decode — so the cap is re-enforced
        // here, against the decode bytes, to defer it off the ready path. The bootstrap excludes
        // legacy artifacts, so the summary read above is the cheap skip path (no full decode).
        if let syncDecodeRuleCap, ruleCount > syncDecodeRuleCap {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-over-sync-cap", details: [
                "identity": summary.identity.fingerprint,
                "ruleCount": "\(ruleCount)",
                "syncCap": "\(syncDecodeRuleCap)"
            ])
            return (nil, "over-sync-cap")
        }
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-over-budget", details: [
                "identity": summary.identity.fingerprint,
                "ruleCount": "\(ruleCount)"
            ])
            return (nil, "over-budget")
        }

        guard let snapshot = try? CompactFilterSnapshot.decode(from: data) else {
            return (nil, "decode-failed")
        }
        return (snapshot, nil)
    }

    private func compactReuseRejectionReason(
        summary: CompactFilterSnapshotSummary,
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> String? {
        guard summary.resolver.transport == configuration.resolverPreset.transport else {
            return "resolverTransport"
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard cachedCatalog != nil else { return "noCachedCatalog" }
            guard summary.coversEnabledBlocklists(in: configuration) else { return "coverage" }
        }

        if let cachedCatalog {
            let expectedIdentity = PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: cachedCatalog
            )
            let mismatches = summary.identity.snapshotInputMismatches(against: expectedIdentity)
            return mismatches.isEmpty ? nil : "inputs:\(mismatches.joined(separator: "+"))"
        }

        return summary.identity.hasSameConfigurationInputs(as: configuration) ? nil : "configInputs"
    }

    // Last-known-good fallback for a failed fresh (re)compile (the rotating-upstream /
    // stale-pinned-hash wedge). Mirrors `reusableCompactSnapshot` — single `.mappedIfSafe`
    // read, header gate BEFORE the multi-MB decode, budget gate, decode from the SAME
    // bytes — but swaps the strict catalog-hash reuse gate for `canServeAsLastKnownGood`,
    // which tolerates ONLY stale catalog/guardrail content hashes while still requiring the
    // same configuration inputs + coverage + resolver transport. So it never fails OPEN (the
    // enabled-list set must match exactly) and a parser-rules bump still forces a
    // regenerate; it only re-serves the user's own previously-compiled, previously-verified
    // rules a few hours stale rather than clearing protection to zero on a cold start.
    // Compact-only by design: the store always dual-writes compact+prepared, and any
    // prepared-only artifact predates the parser-version field (decodes as 0) so a current
    // build regenerates it regardless — there is nothing a prepared fallback could serve.
    private func lastKnownGoodCompactSnapshot(
        from store: FilterArtifactStore,
        configuration: AppConfiguration
    ) -> CompactFilterSnapshot? {
        guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]),
              let summary = try? CompactFilterSnapshot.readSummary(from: data),
              summary.canServeAsLastKnownGood(for: configuration)
        else {
            return nil
        }

        let ruleCount = summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-last-known-good-over-budget", details: [
                "identity": summary.identity.fingerprint,
                "ruleCount": "\(ruleCount)"
            ])
            return nil
        }

        return try? CompactFilterSnapshot.decode(from: data)
    }

    // Cold-start ONLY: the synchronous fast-resume decode is attempted up to this rule count.
    // Measured CompactFilterSnapshot.decode (release) ≈ 0.18 ms / 1K rules — the O(rules)
    // sorted-order verification dominates — so ~1M ≈ ~180 ms on a Mac / ~0.4–0.5 s on device.
    // Above the cap, fail-closed bootstrap defers the decode to the async load (a brief window)
    // rather than stalling tunnel-ready ~0.5 s+ on EVERY connect for a near-budget filter.
    private static let maxSynchronousBootstrapRuleCount = 1_000_000

    // Synchronous cold-start fast-resume: returns the user's own STRICT-reusable, in-budget,
    // summary-schema on-disk snapshot (the current artifact) so a fresh process — notably one
    // relaunched by a self-reconnect that killed the previous process — does NOT serve a block-all
    // FailClosedRuntimeSnapshot window while the async load decodes. Reuses the SAME budget/header-
    // gated reuseCompactSnapshot as the async path, capped to the synchronous-decode ceiling.
    // Returns nil (→ fail-closed bootstrap, async load resumes) when no strict-reusable in-budget
    // summary-schema artifact exists, it exceeds the cap, or it is legacy. NEVER fails open — and
    // deliberately serves NO last-known-good here (that would risk under-blocking with stale rules;
    // the async serveLastKnownGoodOrFailClosed provides LKG when the fresh compile genuinely fails).
    private func bootstrapResidentSnapshotFromDisk(
        configuration: AppConfiguration
    ) -> (snapshot: any FilterRuntimeSnapshot, identity: PreparedFilterSnapshotIdentity)? {
        let cachedCatalog = loadCachedCatalogMetadata()
        let cap = Self.maxSynchronousBootstrapRuleCount

        // Same [pointer-resolved, root, tunnel-compiled] store order as
        // loadCompiledSnapshot — a stale pointer must not shadow a fresh root copy, and
        // the app-published stores are preferred over the tunnel's own retained compile
        // (identity gating makes the order correctness-neutral; preference only decides
        // which equally-reusable copy is decoded).
        var artifactStores: [(store: FilterArtifactStore, route: String)] = []
        if let containerURL = LavaSecAppGroup.containerURL {
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            if let resolved = readableArtifactStore() {
                let route = resolved.directoryURL == rootStore.directoryURL ? "root" : "resolved"
                artifactStores.append((store: resolved, route: route))
            }
            if artifactStores.first?.store.directoryURL != rootStore.directoryURL {
                artifactStores.append((store: rootStore, route: "root"))
            }
        }
        if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {
            artifactStores.append((store: tunnelCompiledStore, route: "tunnel-compiled"))
        }

        // Cheap, skip-only gate BEFORE any reuse/LKG read (which call readSummary). Two reasons
        // it must happen here and not inside the helpers:
        //  1. CAP — readSummary's cheap path only applies to summary-schema artifacts; for a
        //     legacy artifact it FULL-DECODES the rule tables, so checking the cap after
        //     readSummary would make a large legacy artifact pay a full decode just to be rejected.
        //  2. LEGACY EXCLUSION — even UNDER the cap, a legacy artifact would be decoded twice
        //     synchronously (readSummary's legacy recompute, then reusableCompactSnapshot's
        //     decode), ~2x the sync budget. Legacy artifacts are transient (regenerated on the
        //     next publish), so skip them and let the async load decode them once off the
        //     critical path. readSyncBootstrapInfo reports both signals in one skip-only read.
        // The same filter yields the same count across stores.
        var maxRuleCount = 0
        var eligibleStores: [(store: FilterArtifactStore, route: String)] = []
        for (store, route) in artifactStores {
            guard FileManager.default.fileExists(atPath: store.compactSnapshotURL.path) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "missing"
                ])
                continue
            }
            guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "unreadable"
                ])
                continue
            }
            guard let info = try? CompactFilterSnapshot.readSyncBootstrapInfo(from: data) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "invalid"
                ])
                continue
            }
            maxRuleCount = max(maxRuleCount, info.totalRuleCount)
            guard info.hasStoredSummary else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-skip-legacy-artifact", details: [
                    "route": route,
                    "ruleCount": "\(info.totalRuleCount)"
                ])
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "legacy",
                    "ruleCount": "\(info.totalRuleCount)"
                ])
                continue
            }
            if info.totalRuleCount > cap {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-over-sync-cap", details: [
                    "route": route,
                    "ruleCount": "\(info.totalRuleCount)",
                    "syncCap": "\(cap)"
                ])
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "over-sync-cap",
                    "ruleCount": "\(info.totalRuleCount)",
                    "syncCap": "\(cap)"
                ])
                continue
            }
            eligibleStores.append((store: store, route: route))
        }

        for (store, route) in eligibleStores {
            let compactResult = reusableCompactSnapshot(
                from: store,
                configuration: configuration,
                cachedCatalog: cachedCatalog,
                syncDecodeRuleCap: cap
            )
            if let compact = compactResult.snapshot {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-compact-resume", details: [
                    "route": route,
                    "identity": compact.identity.fingerprint
                ])
                return (compact, compact.identity)
            }
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                "route": route,
                "reason": compactResult.missReason ?? "unknown",
                "syncCap": "\(cap)"
            ])
        }
        // No strict-reusable, sync-eligible CURRENT artifact → fail closed; the async load handles
        // everything else off the critical path. Deliberately NO last-known-good resume here: a
        // config-matched-but-stale artifact (e.g. a smaller preserved root copy while the current
        // artifact is reusable-but-over-cap) would UNDER-BLOCK domains added since it was built,
        // breaking the over-cap-→-fail-closed guarantee. The async serveLastKnownGoodOrFailClosed
        // still provides last-known-good when the fresh (re)compile genuinely fails.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-fast-resume-miss", details: [
            "reason": eligibleStores.isEmpty ? "no-eligible-stores" : "strict-miss",
            "storeCount": "\(artifactStores.count)",
            "eligibleStoreCount": "\(eligibleStores.count)",
            "syncCap": "\(cap)",
            "maxRuleCount": "\(maxRuleCount)"
        ])
        return nil
    }

    // Legacy fallback. The manifest and the prepared file are read SEPARATELY (prepared
    // is JSON with no cheap header, so — unlike `reusableCompactSnapshot` — the gate and
    // the decode can't share one mmapped `Data`). The manifest pre-gate (identity +
    // budget, manifest written LAST) only skips a doomed decode; it is NOT the authority.
    // Because the mutable root store can be atomically republished between the two reads,
    // a concurrent publish could otherwise pair gen-N's in-budget manifest with gen-(N+1)'s
    // over-budget prepared bytes. So after decoding we re-bind the prepared to the manifest
    // (identity, generatedAt, summary — mirroring `FilterArtifactStore.preparedSelection`)
    // and re-check the budget against the prepared's OWN summary, making the over-budget
    // refusal TOCTOU-safe like the compact path. The versioned store is immutable, so this
    // skew only exists on root; the cross-check is cheap and closes it everywhere.
    private func reusablePreparedSnapshot(
        from store: FilterArtifactStore,
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> (snapshot: PreparedFilterSnapshot?, missReason: String?) {
        guard FileManager.default.fileExists(atPath: store.manifestURL.path) else {
            return (nil, "manifest-missing")
        }
        guard let manifest = (try? store.loadManifest()).flatMap({ $0 }) else {
            return (nil, "manifest-invalid")
        }
        if let reuseRejection = manifest.reuseRejectionReason(
            configuration: configuration,
            cachedCatalog: cachedCatalog
        ) {
            return (nil, "reuse:\(reuseRejection)")
        }

        let manifestRuleCount = manifest.summary.blockRuleCount + manifest.summary.allowRuleCount + manifest.summary.guardrailRuleCount
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: manifestRuleCount) else {
            return (nil, "over-budget")
        }

        guard FileManager.default.fileExists(atPath: store.preparedSnapshotURL.path) else {
            return (nil, "missing")
        }
        guard let prepared = loadPreparedSnapshot(from: store) else {
            return (nil, "decode-failed")
        }
        guard prepared.identity == manifest.snapshotIdentity,
              prepared.snapshot.generatedAt == manifest.generatedAt,
              prepared.summary == manifest.summary
        else {
            return (nil, "manifest-mismatch")
        }

        // Authority gate: the decoded prepared's OWN rule count, not the manifest's, so a
        // root republish between the two reads can never make an over-budget generation
        // resident (the 2x-resident jetsam the budget guard exists to prevent).
        let ruleCount = prepared.summary.blockRuleCount + prepared.summary.allowRuleCount + prepared.summary.guardrailRuleCount
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-prepared-over-budget", details: [
                "identity": prepared.identity.fingerprint,
                "ruleCount": "\(ruleCount)"
            ])
            return (nil, "over-budget")
        }

        guard prepared.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: cachedCatalog) else {
            return (nil, "decoded-reuse-mismatch")
        }
        return (prepared, nil)
    }

    private func loadPreparedSnapshot(from store: FilterArtifactStore) -> PreparedFilterSnapshot? {
        guard let data = try? Data(contentsOf: store.preparedSnapshotURL) else {
            return nil
        }

        return try? JSONDecoder().decode(PreparedFilterSnapshot.self, from: data)
    }

    private func loadCachedCatalogMetadata() -> BlocklistCatalog? {
        guard let catalogCacheURL else {
            return nil
        }

        return try? BlocklistCatalogSynchronizer(
            cacheDirectoryURL: catalogCacheURL
        ).loadCachedCatalogMetadata()
    }

    private var catalogCacheURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(
            LavaSecAppGroup.catalogCacheDirectoryName,
            isDirectory: true
        )
    }

    // The tunnel's own last successful in-extension compile, retained by
    // StreamingCompactSnapshotCompiler at a stable path so a later cold start can
    // fast-resume from it when the app-published artifact store lags the cached
    // catalog. UR-48 field log: the app had not republished after a catalog rotation,
    // so EVERY tunnel start strict-missed both app stores (root manifest-missing,
    // resolved reuse:inputs), served the transient fail-closed bootstrap, and repeated
    // a ~7 s / 356k-rule recompile — the outage window #294 bounds and this removes.
    // Read-gated exactly like the app's stores (identity + budget + sync cap), so a
    // stale retained compile is rejected, never served. Lives under the catalog cache
    // dir — OUTSIDE the app-owned store/pointer layout, so app publishes and versioned
    // GC never race it — and is a FilterArtifactStore only to reuse compactSnapshotURL
    // naming and the shared read helpers (its manifest/prepared slots are never written).
    private static let tunnelCompiledArtifactDirectoryName = "tunnel-compiled-artifact"

    private var tunnelCompiledArtifactStore: FilterArtifactStore? {
        catalogCacheURL.map {
            FilterArtifactStore(directoryURL: $0.appendingPathComponent(
                Self.tunnelCompiledArtifactDirectoryName,
                isDirectory: true
            ))
        }
    }

    // Read-side accessor: nil until a compile has actually been retained, so devices
    // that never in-extension compile (the healthy fast-resume path) add no per-start
    // store-miss log lines or stat reads for a file that has never existed.
    private func retainedTunnelCompiledArtifactStoreIfPresent() -> FilterArtifactStore? {
        guard let store = tunnelCompiledArtifactStore,
              FileManager.default.fileExists(atPath: store.compactSnapshotURL.path)
        else {
            return nil
        }
        return store
    }

    private var configurationURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.configurationFilename)
    }

    private var diagnosticsURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsFilename)
    }

    private var networkActivityLogURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.networkActivityLogFilename)
    }

    private var diagnosticsControlURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsControlFilename)
    }

    private func modificationDate(for url: URL?) -> Date? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else {
            return nil
        }

        return attributes[.modificationDate] as? Date
    }
}

// MARK: - Private DNS wire, socket & factory types

// Provider-local naming for the Kit-plan type (predates the split; kept to avoid
// touching ~40 call sites in this file).
private typealias ResolverRuntimeConfiguration = DNSResolverRuntimePlan

// The pure DNS wire/socket tail types (IPv4UDPDNSPacket, resolver endpoints,
// UDP/TCP socket resolvers, DNSMessageTraits, bootstrap wire helpers) moved to
// LavaSecDNS in Phase E1 — now public API with executable tests instead of
// source pins. See Sources/LavaSecDNS/.

private final class SendableCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}

/// `SettleWorkScheduling` backed by a one-shot `DispatchSourceTimer` on the
/// tunnel's `dnsStateQueue`, mirroring the existing `protectionPauseResumeTimer`
/// idiom. Used by the resolver-probe coalescer (plan item 430).
private final class DispatchSettleWorkScheduler: SettleWorkScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(after interval: TimeInterval, _ work: @escaping () -> Void) -> SettleWorkToken {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler {
            work()
        }
        timer.resume()
        return DispatchSettleWorkToken(timer: timer)
    }
}

private final class DispatchSettleWorkToken: SettleWorkToken {
    private let timer: DispatchSourceTimer
    private var isCancelled = false

    init(timer: DispatchSourceTimer) {
        self.timer = timer
    }

    func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        timer.cancel()
    }
}
