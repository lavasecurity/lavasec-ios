import Foundation
import LavaSecKit

enum LavaSecAppGroup {
    static let identifier = "group.com.lavasec"
    static let snapshotFilename = "filter-snapshot.json"
    static let compactSnapshotFilename = "filter-snapshot.compact"
    static let configurationFilename = "app-configuration.json"
    // The library of hosted filters + which one is active (multi-filter). The four
    // filter-scoped fields of the active filter are mirrored into `app-configuration.json`
    // so the tunnel + the ~25 existing config readers are untouched; this file is the
    // source of truth for the set of filters and the active selection.
    static let filterLibraryFilename = "filter-library.json"
    // Sidecar warm-index (Focus auto-switch Phase 2). The background BGTask is the SOLE writer;
    // the foreground only reads it (and promotes valid entries into filter-library.json). Kept
    // separate from filter-library.json so background warming can never clobber a foreground edit.
    static let backgroundWarmIndexFilename = "background-warm-index.json"
    static let tunnelHealthFilename = "tunnel-health.json"
    static let diagnosticsFilename = "diagnostics.json"
    static let diagnosticsControlFilename = "diagnostics-control.json"
    /// SQLite depth store for Domain History (`DNSEventLog`): tunnel-writes, app-reads-only.
    /// Separate from `diagnostics.json` — the JSON store keeps the aggregate counts + the
    /// last-250 events; this holds the full 7-day event stream the scrollable list pages over.
    static let dnsEventLogFilename = "dns-events.sqlite"
    /// Epoch-ms floor written by the app when the user clears Domain History; the read path
    /// hides log rows older than this so a clear takes effect without a cross-process sqlite
    /// write (the tunnel prunes them physically on its next retention pass).
    static let dnsEventLogClearedAtKeyName = "dnsEventLogClearedAtMs"
    static let networkActivityLogFilename = "network-activity-log.json"
    /// OBS R2: the append-only incident ledger — tunnel-writes, app-reads-at-report-time.
    /// Decoupled from the rate-limiter's policy stores (which forget by design); nothing
    /// in the recovery/cap policy reads this file.
    static let incidentLedgerFilename = "incident-ledger.json"
    static let catalogCacheDirectoryName = "catalog-cache"
    static let reloadSnapshotMessage = "reload-snapshot"
    static let reloadProtectionPauseMessage = "reload-protection-pause"
    static let reloadConfigurationMessage = "reload-configuration"
    static let clearDiagnosticsMessage = "clear-diagnostics"
    static let clearFilteringCountsMessage = "clear-filtering-counts"
    static let clearNetworkActivityLogMessage = "clear-network-activity-log"
    static let clearIncidentLedgerMessage = "clear-incident-ledger"
    static let flushTunnelHealthMessage = "flush-tunnel-health"
    static let vpnDebugLogFilename = "vpn-debug-log.jsonl"
    /// The single previous generation kept by `LavaSecDeviceDebugLog.rotate` (same
    /// `+ ".1"` convention as its `rotatedURL(for:)`). Report/export loaders read it so an
    /// 8 MB rotation landing between an incident and the report can't hide the incident.
    static let vpnDebugLogRotatedFilename = vpnDebugLogFilename + ".1"
    /// Cross-process advisory lock serializing `LavaSecDeviceDebugLog.rotate` (PST-2/CON-5).
    /// App + tunnel + every NWConnection queue append to the same log; without this, two
    /// processes crossing the 8 MB cap at once double-rotate — writer B's removeItem deletes
    /// writer A's fresh `.1` and installs a near-empty file over it, destroying the rotated
    /// generation the report/export loaders read under incident load. A dedicated `.lock`
    /// sibling (not any of the config/command locks) so log rotation never blocks — or is
    /// blocked by — a filter publish or a protection command.
    static let vpnDebugLogRotationLockFilename = vpnDebugLogFilename + ".rotate.lock"
    static let protectionNotificationRouteUserInfoKeyName = "lavaRoute"
    static let protectionNotificationGuardRouteValue = "guard"
    static let protectionNotificationRequestIdentifierPrefix = "com.lavasec.protection."
    /// Request-identifier prefix for the simple EVENT notifications (filter switched / couldn't apply /
    /// paused-resumed) posted via `LavaEventNotificationPoster`. Distinct from the connectivity prefix so
    /// the two families never collide or supersede each other.
    static let eventNotificationRequestIdentifierPrefix = "com.lavasec.event."
    /// Best-effort "the app is in the foreground RIGHT NOW" flag (Bool), written by the app on scene-phase
    /// transitions and read by the App Intents extension to gate the filter-switch notification to
    /// closed/backgrounded only (the foreground app shows the switch in-UI, so a banner would be redundant).
    /// Distinct from the REMOVED `AppForegroundActivityState` switch-defer machinery (no stale window, no
    /// effect on the switch itself) — a wrong read at worst shows/suppresses one cosmetic notification.
    static let appForegroundActiveDefaultsKeyName = "lavasec.app.foregroundActive"
    static let protectionNotificationKindUserInfoKeyName = "lavaNotificationKind"
    static let protectionNotificationIDUserInfoKeyName = "lavaNotificationID"
    static let protectionLastDeliveredNotificationIDDefaultsKeyName = "lavasec.protection.lastDeliveredNotificationID"
    static let protectionLastDeliveredNotificationAtDefaultsKeyName = "lavasec.protection.lastDeliveredNotificationAt"
    static let protectionUnresolvedProblemNotificationIDDefaultsKeyName = "lavasec.protection.unresolvedProblemNotificationID"
    static let protectionUnresolvedProblemNotificationKindDefaultsKeyName = "lavasec.protection.unresolvedProblemNotificationKind"
    static let protectionNotificationKindSchemaVersionDefaultsKeyName = "lavasec.protection.notificationKindSchemaVersion"
    // Written by the app only after `saveToPreferences` confirms Connect-On-Demand
    // is armed/disarmed, and read by the tunnel to gate self-reconnect: a self-
    // cancel only recovers if on-demand will bring the tunnel back, and the app
    // persists `protectionEnabled = true` even when arming on-demand fails.
    static let protectionOnDemandConfirmedEnabledDefaultsKeyName = "lavasec.protection.onDemandConfirmedEnabled"
    // Deadline (Double, timeIntervalSinceReferenceDate) marking a Dynamic Island
    // Restart as in progress. Written by the Restart command, read by the app's
    // status reconcile so it reports `.restarting` (instead of clobbering the
    // transient with `.on`/end via the status notifications the restart emits) and
    // so a second concurrent Restart tap is rejected. Stored as a deadline so a
    // killed background intent window auto-clears it.
    static let protectionRestartInFlightUntilDefaultsKeyName = "lavasec.protection.restartInFlightUntil"
    // The tunnel persists its recent self-reconnect attempt timestamps ([Double] epoch seconds)
    // here for the cooldown/cap policy. Shared so the app can READ the self-reconnect timeline for
    // a bug report's incident summary (LAV-94 B) without touching the tunnel's frozen recovery
    // path. The tunnel's own `selfReconnectAttemptsDefaultsKeyName` literal is locked to this value by
    // a source test (PacketTunnelDNSRuntimeSourceTests) so the two can never drift.
    static let selfReconnectAttemptTimesDefaultsKeyName = "tunnel.selfReconnectAttemptTimes"
    // Durable self-reconnect GAP evidence (LAV-92/93 observability). The attempt store above
    // forgets BY DESIGN (productive credit deletes the recovered attempt; the report prunes to
    // the 600 s policy window), so these carry the field-visible record instead: GapStartedAt
    // is stamped at teardown commit; GapEndedAt at the NEXT tunnel launch (the process is
    // serving again — the honest Guard-off window, however long the relaunch took); GapCount
    // is the cumulative committed-teardown count. Written by the tunnel only (epoch seconds /
    // integer); the app READS them into the bug report's incident summary.
    static let selfReconnectGapStartedAtDefaultsKeyName = "tunnel.selfReconnectGapStartedAt"
    static let selfReconnectGapEndedAtDefaultsKeyName = "tunnel.selfReconnectGapEndedAt"
    static let selfReconnectGapCountDefaultsKeyName = "tunnel.selfReconnectGapCount"
    // Aliased to the LavaSecKit stores so the app, tunnel, intents, and the
    // stores can never drift on key strings.
    static let protectionActiveSessionIDDefaultsKey = ProtectionSessionStore.Keys.activeSessionID
    static let protectionTemporaryPauseUntilDefaultsKey = ProtectionPauseStore.Keys.pausedUntil
    static let protectionTemporaryPauseSessionIDDefaultsKey = ProtectionPauseStore.Keys.pausedSessionID
    static let protectionCommandRevisionDefaultsKey = ProtectionPauseStore.Keys.commandRevision
    static let protectionCommandLockFilename = "protection-command.lock"
    // Serializes concurrent headless Focus warm-switches (LAV-100 Phase 3). A dedicated lock (not the
    // protection-command lock) so a Focus switch and a Live Activity pause/resume never block each
    // other. (Cross-process write-safety against the FOREGROUND writer is the separate
    // configurationWriteLock + generation fence below, taken by both sides; this lock only serializes
    // concurrent headless switches with each other.)
    static let focusFilterSwitchLockFilename = "focus-filter-switch.lock"
    // Cross-process CAS for the shared (config, library) pair write (LAV-100 Phase 4). The Phase-3
    // single-@MainActor-funnel invariant held only while every writer ran in ONE process; the App
    // Intents EXTENSION is now a second writer process, so SharedFilterStatePersistence's read-generation
    // -then-write critical section is wrapped in an exclusive lock on this file — taken by BOTH the
    // foreground publishers and the extension's commit — so two processes can never read the same on-disk
    // generation or interleave the two file writes.
    static let configurationWriteLockFilename = "app-configuration-write.lock"
    // Cross-process lock for the pending-Focus-switch MARKER (LAV-100 Phase 4). The marker's
    // compare-and-clear was safe only while every mutator ran on the app's @MainActor; the App Intents
    // extension now RECORDS from a second process, so the extension's `record` and the foreground's
    // `clearIfMatches` take this shared lock so a record can't interleave a clear's read→remove (which
    // would silently drop a just-recorded Focus request).
    static let pendingFilterSwitchMarkerLockFilename = "focus-filter-marker.lock"
    // Content-addressed pointer-swap substrate for the shared filter-artifact set
    // (LAV-90 Phase 1). The lock arbitrates writer-vs-writer only; the tunnel reads
    // the pointer-swapped set lock-free. App + tunnel share these strings.
    static let filterArtifactPublishLockFilename = "filter-artifact-publish.lock"
    static let filterArtifactsDirectoryName = "filter-artifacts"
    static let filterArtifactPointerFilename = "current.json"
    static let customizationLavaGuardLookDefaultsKeyName = "lavasec.customization.lavaGuardLook"
    static let latencyOperationIDOptionKeyName = "lavasec.latency.operationID"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// The shared app-group `UserDefaults`, falling back to `.standard` if the
    /// group container is unavailable. Single source so the app, tunnel, intents,
    /// and command service can't drift onto `.standard` by accident.
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    static func protectionNotificationRequestIdentifier(for identifier: String) -> String {
        "\(protectionNotificationRequestIdentifierPrefix)\(identifier)"
    }

    /// One-time migration of the persisted connectivity-notification state across the
    /// notification-kind vocabulary change (slow-DNS got its own kind). Idempotent and
    /// version-gated, so it's safe to call on every scheduling pass in both processes.
    static func migrateProtectionNotificationStateIfNeeded(_ defaults: UserDefaults = sharedDefaults) {
        ProtectionConnectivityNotificationStore.migrateLegacyKindSchemaIfNeeded(
            in: defaults,
            keys: ProtectionConnectivityNotificationStore.DefaultsKeys(
                schemaVersion: protectionNotificationKindSchemaVersionDefaultsKeyName,
                unresolvedProblemKind: protectionUnresolvedProblemNotificationKindDefaultsKeyName
            )
        )
    }
}

struct LavaSecProviderMessage: Equatable {
    let kind: String
    let operationID: String?
}

enum LavaSecProviderMessageCodec {
    private struct Envelope: Codable {
        let kind: String
        let operationID: String?
    }

    static func encode(kind: String, operationID: String?) -> Data {
        let envelope = Envelope(kind: kind, operationID: operationID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data(kind.utf8)
    }

    static func decode(_ data: Data) -> LavaSecProviderMessage? {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return LavaSecProviderMessage(kind: envelope.kind, operationID: envelope.operationID)
        }

        guard let rawKind = String(data: data, encoding: .utf8) else {
            return nil
        }

        return LavaSecProviderMessage(kind: rawKind, operationID: nil)
    }
}

// Compiled in all configurations (including Release/TestFlight) so the optional
// Feedback report can carry the on-device VPN diagnostics. A privacy audit of
// every append site confirmed no event records a queried domain (only resolver
// endpoints, health/outcome metadata, and tunnel state); the user's domain
// history lives separately in the user-controlled DiagnosticsStore. The 8 MB cap
// plus rotation bounds the on-device footprint.
enum LavaSecDeviceDebugLog {
    // Cap keeps the on-device log from growing without bound (an 88.9 MB file was
    // observed during QA); one rotated generation is kept for dump tooling.
    static let maxLogFileBytes: UInt64 = 8 * 1024 * 1024

    // ISO8601DateFormatter is documented thread-safe; allocating one per append
    // showed up in heat triage as avoidable per-event cost.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    static func reset() {
        guard let url = logURL else {
            return
        }

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: rotatedURL(for: url))
    }

    // DESIGN / ENERGY TRADE-OFF (NRG — deferred, no behavior change here):
    // This logger is compiled in Release (see the privacy-audit note above) and is
    // injected into every resolver transport + dozens of tunnel event sites, so on
    // a busy tunnel it appends many lines per minute. Each `append` currently does
    // a synchronous open(2) + fstat(2) + write(2) + close(2) per line (see
    // `appendLine` / `openForAppend`) — a syscall triplet on the DNS-serving path.
    // The cost is intentional TODAY for two reasons that a batching change must not
    // regress:
    //   1. ATOMICITY / ORDER: `O_APPEND` with a single `write(2)` per line is what
    //      keeps concurrent appends from the app + tunnel (+ every NWConnection
    //      queue) from tearing each other's JSONL lines — the prior seek-then-write
    //      path produced corrupted dumps. A batched/deferred flush must preserve
    //      cross-thread + cross-process atomicity and total ordering.
    //   2. DURABILITY FOR FEEDBACK: events written here survive into the optional
    //      Feedback report even if the process is jetsamed mid-session; a purely
    //      in-memory ring that drops on a hard kill would lose incident evidence.
    // The deferred optimization is a bounded in-memory ring flushed on a debounce
    // (mirroring `DebouncedPersistenceController`), collapsing N syscall triplets
    // per interval into one batched write — but it must keep the 8 MB cap +
    // rotation invariants, the non-blocking `try()`-lock rotation guards (CON-1:
    // rotation must never block a DNS writer), and the privacy audit (no event may
    // record a queried domain).
    //
    // SCOPE (review 2026-07-05): after the #285 hot-path pass this is NOT a
    // per-query cost in Release — query-begin traces are DEBUG/QA-only, query-result
    // logs are failure-only, DoH/DoT connection-ready fires only on a FRESH
    // (non-reused) connection, and DoQ's per-query ready line is dropped in Release.
    // The "many lines per minute" above is the busy/DEBUG framing; the honest
    // Release residual is connection-lifecycle + periodic-timer + failure sites —
    // low-frequency, bursty, pure CPU (no radio). Measure the actual Release append
    // rate on-device before spending effort here; the triplet is wasteful per append
    // but small at today's rate.
    //
    // MIDDLE-PATH APPRAISAL: neither obvious batching wins cleanly. (A) a persistent
    // fd (drop open+close per line) nets only ~25% once made rotation-safe — a held
    // fd keeps writing into the renamed `.1` after another process rotates (link
    // count stays 1, so it needs a per-line path/inode compare, not a zero-link
    // check), and the naive open-once orphans the fd across two rotations, giving
    // unbounded `.1` growth + lost lines on exit. (B) the debounced ring above trades
    // away the jetsam-durability invariant during the incident window where volume
    // actually peaks, and ADDS a flush timer (a new periodic wake) — net-negative for
    // battery. Per-append CPU is anyway dominated by the JSON encode + timestamp
    // format below, not the syscalls. Deferred; not worth either regression today.
    static func append(component: String, event: String, details: [String: String] = [:]) {
        #if DEBUG || LAVA_QA_TOOLS
        // NRG debug-log lever: count real appends only. Skip the "nrg" component (the
        // nrg-counters flush's own append) so a quiet window can't inherit a synthetic
        // debugLogAppend from the previous summary write.
        if component != "nrg" {
            EnergyCounters.shared.bump(.debugLogAppend)
        }
        #endif
        guard let url = logURL else {
            return
        }

        var payload = details
        payload["component"] = component
        payload["event"] = event
        payload["timestamp"] = timestampFormatter.string(from: Date())

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else {
            return
        }

        appendLine(data + Data("\n".utf8), to: url)
    }

    // The app and tunnel processes append to the same file. O_APPEND with a single
    // write(2) per line keeps concurrent appends from tearing each other; the old
    // seekToEnd-then-write path produced corrupted JSONL lines in device dumps.
    private static func appendLine(_ line: Data, to url: URL) {
        guard var descriptor = openForAppend(url) else {
            return
        }

        var info = stat()
        if fstat(descriptor, &info) == 0, info.st_size >= Int64(maxLogFileBytes) {
            close(descriptor)
            rotate(url)
            guard let reopened = openForAppend(url) else {
                return
            }
            descriptor = reopened
        }

        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            _ = write(descriptor, base, buffer.count)
        }
        close(descriptor)
    }

    private static func openForAppend(_ url: URL) -> Int32? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        return descriptor >= 0 ? descriptor : nil
    }

    // Serializes rotation among THIS process's threads. On Darwin an `flock` taken via a separate
    // descriptor in the SAME process does not reliably conflict (see FilterPublishLockTests), so the
    // cross-process advisory lock below does NOT exclude two threads of this process — e.g. concurrent
    // DoH/DoT/DoQ debug-logger callbacks both crossing the cap. This non-blocking in-process lock is
    // the same-process half of the exclusion (Codex #212).
    private static let rotationInProcessLock = NSLock()

    // The app and tunnel (and every NWConnection queue) can cross the cap at the same
    // instant. Without exclusion, two rotations race: writer B's removeItem deletes writer A's
    // freshly-rotated `.1` and moveItem installs a near-empty file over it, destroying the rotated
    // generation the report/export loaders (#183) read under incident load. `rotate` runs under TWO
    // non-blocking guards, so it excludes both same-process threads and other processes:
    //   - IN-PROCESS: `rotationInProcessLock.try()` — the cross-process flock alone can't exclude
    //     same-process threads on Darwin (Codex #212). If another thread here holds it, that thread is
    //     already rotating — skip.
    //   - CROSS-PROCESS: a NON-BLOCKING exclusive advisory lock (`flock(LOCK_EX | LOCK_NB)`, via
    //     `FilterPublishLock.withTryExclusiveLock`). If contended, another process is rotating — skip.
    // Both guards are try-only: this runs on the tunnel's DNS-serving path (CON-1), so a rotation must
    // NEVER block a writer — a skipped rotation just retries on the next append.
    //   - After acquiring the locks, RE-FSTAT the log: the over-cap size was read (in appendLine)
    //     BEFORE we held them, so a writer serialized AHEAD of us may have already rotated, leaving a
    //     fresh (below-cap) file. Skip if it is no longer over cap — the re-check is what prevents the
    //     double-rotate that deletes the fresh generation.
    private static func rotate(_ url: URL) {
        // In-process guard FIRST: non-blocking, so a second thread that is already rotating here makes
        // this call skip rather than run a concurrent removeItem/moveItem (Codex #212).
        guard rotationInProcessLock.`try`() else { return }
        defer { rotationInProcessLock.unlock() }

        // `withTryExclusiveLock` returns `Void?` (nil when contended / lock unavailable); the
        // rotation is best-effort so the outcome is deliberately discarded.
        _ = FilterPublishLock.withTryExclusiveLock(at: rotationLockURL) {
            // Re-check under the lock: the over-cap size was read (in appendLine) BEFORE we held
            // the lock, so a writer serialized ahead of us may have already rotated, leaving a
            // fresh (below-cap) file we must leave alone.
            guard let descriptor = openForAppend(url) else {
                return
            }
            var info = stat()
            let stillOverCap = fstat(descriptor, &info) == 0 && info.st_size >= Int64(maxLogFileBytes)
            close(descriptor)
            guard stillOverCap else {
                return
            }

            let rotated = rotatedURL(for: url)
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
    }

    private static func rotatedURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
    }

    private static var logURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.vpnDebugLogFilename)
    }

    // Sibling of the log in the app-group container so app + tunnel + intents contend on
    // the same inode (`nil` when the container is unavailable → rotation degrades-open, same
    // as the append itself). Never one of the config/command locks: log rotation must not
    // block a filter publish or protection command, or be blocked by one.
    private static var rotationLockURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.vpnDebugLogRotationLockFilename)
    }
}

// QA-ONLY energy-measurement counters — Phase 1 of the energy-measurement plan
// (lavasec-infra docs/engineering/energy-measurement-and-qa-instrumentation-plan.md).
// Compiled ONLY under DEBUG/LAVA_QA_TOOLS: nothing here ships in the App Store build
// (Principle 1 — instrumentation stays strictly in QA), and every call site is
// likewise gated. These aggregate the four deferred energy levers' per-lever event
// rates IN MEMORY and flush ONE `nrg-counters` summary line per ~60 s window to the
// device log, so a measurement run reads rates instead of parsing thousands of
// per-event lines. Crucially the debug-log lever is counted with an in-memory bump,
// never by emitting a log line per append — that would be the observer effect the
// plan warns about. The flush piggybacks the tunnel's existing 60 s Focus poll, so
// it adds no timer (no new wake) of its own.
#if DEBUG || LAVA_QA_TOOLS
enum EnergyCounter: String, CaseIterable {
    case debugLogAppend   // debug-log lever: LavaSecDeviceDebugLog.append calls
    case doqHandshake     // DoQ lever: fresh QUIC handshakes (connection-ready)
    case smokeProbeWire   // smoke-probe lever: probes that hit the wire (radio)
    case smokeProbeSkip   // smoke-probe lever: probes suppressed by NRG-3a evidence
    case focusPollTick    // focus-poll lever: 60 s config-poll wakes
    // SQLite depth-store write path (UR-53 follow-up; energy doc H3.2 re-specced to the
    // batched writer). Fed from DNSEventLog's pulled-per-tick instrumentation snapshot.
    case sqliteFlush      // committed best-effort batch flushes
    case sqliteFlushRows  // rows committed via those flushes
    case sqliteFlushRetry // failed flushes retained for retry (SQLITE_BUSY riding, etc.)
    case sqlitePrunePass  // prune passes on the ~30 s diagnostics cadence
    case sqlitePruneRows  // events aged out by those passes
    case sqliteSweepRun   // orphan-domain sweeps actually taken (post-#339 gate)
    // Field thermal signal for UR-53-class "device feels warm" reports.
    case thermalTransition // ProcessInfo.thermalStateDidChange notifications observed
}

final class EnergyCounters: @unchecked Sendable {
    static let shared = EnergyCounters()

    private let lock = NSLock()
    private var isActive = false
    private var counts: [EnergyCounter: Int] = [:]
    private var doqHandshakeMsSum = 0
    private var sqliteWALFrames: Int64 = 0
    private var lastCPUTimeMs = 0.0
    private var thermalObserver: (any NSObjectProtocol)?
    private var windowStartedAt = Date()
    private var lastFlushAt = Date()
    private static let flushInterval: TimeInterval = 60

    // `bump` is compiled into every process that links Shared (app, tunnel, intents), but only
    // the tunnel drives `flushIfDue` (its 60 s Focus poll). Counting in a process that never
    // flushes would silently drop those counts, so counting is gated to the flushing process:
    // the tunnel calls `activate()` once at startup and every other process stays a no-op. The
    // debug-log lever IS the DNS-serving path (the tunnel), so scoping it this way is intentional,
    // not a lost measurement.
    // Reset the window on each activation so each tunnel session's measurement is
    // isolated: a stop/start within the same (un-killed) extension process would
    // otherwise carry the previous session's counts + an idle `windowSec` gap into
    // the first nrg-counters line, skewing the rates. Called once per startTunnel.
    func activate() {
        let now = Date()
        lock.lock()
        isActive = true
        counts = [:]
        doqHandshakeMsSum = 0
        sqliteWALFrames = 0
        // CPU baseline: rusage is process-cumulative, so the first window's delta must
        // start at activation, not at zero, or it would inherit pre-activation CPU.
        lastCPUTimeMs = Self.processCPUTimeMs()
        windowStartedAt = now
        lastFlushAt = now
        // Count thermal-state transitions for the window (field signal for UR-53-class
        // "device feels warm" reports). Re-registering per activation keeps one observer
        // per (re)started tunnel session; the closure only bumps under the lock.
        // ORDER is the fix for the re-activation double-count, and it must be
        // remove-BEFORE-add: NotificationCenter fixes a post's delivery set at post time,
        // so a transition posted while both observers are registered merely BLOCKS both
        // callbacks on this lock and then bumps twice after unlock — holding the lock
        // across the swap serializes the bumps without deduplicating them (Codex P3,
        // PR #351 round 6, correcting the atomicity framing from the earlier rounds).
        // With remove-first there is never an instant with two observers; the residual is
        // an at-most-one UNDERcount for a transition landing in the remove→add gap of a
        // startTunnel activation — the right side to err on for a QA rate counter.
        if let previousObserver = thermalObserver {
            NotificationCenter.default.removeObserver(previousObserver)
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.bump(.thermalTransition)
        }
        lock.unlock()
    }

    // Feed one pulled DNSEventLog write-path window (the tunnel pulls a snapshot per 60 s
    // Focus tick). Counts and the WAL-frame gauge land under ONE lock so a concurrent flush
    // can't split a window across two summary lines.
    func recordSQLiteWindow(_ snapshot: DNSEventLog.WriteInstrumentationSnapshot) {
        lock.lock()
        if isActive {
            counts[.sqliteFlush, default: 0] += snapshot.flushes
            counts[.sqliteFlushRows, default: 0] += snapshot.flushedRows
            counts[.sqliteFlushRetry, default: 0] += snapshot.flushRetries
            counts[.sqlitePrunePass, default: 0] += snapshot.prunePasses
            counts[.sqlitePruneRows, default: 0] += snapshot.prunedRows
            counts[.sqliteSweepRun, default: 0] += snapshot.orphanSweeps
            sqliteWALFrames += snapshot.walFramesWritten
        }
        lock.unlock()
    }

    private static func processCPUTimeMs() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
        let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
        return user + system
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // Atomic increment only — never touches the log (the debug-log lever must not be
    // measured by writing more log lines).
    func bump(_ counter: EnergyCounter) {
        lock.lock()
        if isActive { counts[counter, default: 0] += 1 }
        lock.unlock()
    }

    // Count a DoQ handshake AND add its duration under ONE lock, so a concurrent
    // flush can never snapshot a count without its milliseconds (keeps doqHandshakeAvgMs
    // consistent). `milliseconds` is nil when the ready event carried no timing.
    func recordDoQHandshake(milliseconds: Int?) {
        lock.lock()
        if isActive {
            counts[.doqHandshake, default: 0] += 1
            if let milliseconds { doqHandshakeMsSum += max(0, milliseconds) }
        }
        lock.unlock()
    }

    // Emits at most one `nrg-counters` summary per window; rates are per-minute so
    // windows of slightly different length stay comparable. Safe to call every tick.
    func flushIfDue(now: Date = Date()) {
        lock.lock()
        guard isActive, now.timeIntervalSince(lastFlushAt) >= Self.flushInterval else {
            lock.unlock()
            return
        }
        let elapsed = max(1, now.timeIntervalSince(windowStartedAt))
        let snapshot = counts
        let handshakeMsSum = doqHandshakeMsSum
        let walFrames = sqliteWALFrames
        // Process CPU (user+system) consumed inside this window. The tunnel is the only
        // process that flushes, so this is the DNS-serving process's compute footprint —
        // the field-side stand-in for the wired Activity Monitor attribution the UR-53
        // follow-up ran (no public per-process API beyond rusage exists on iOS).
        let cpuNowMs = Self.processCPUTimeMs()
        let cpuDeltaMs = max(0, cpuNowMs - lastCPUTimeMs)
        lastCPUTimeMs = cpuNowMs
        counts = [:]
        doqHandshakeMsSum = 0
        sqliteWALFrames = 0
        windowStartedAt = now
        lastFlushAt = now
        lock.unlock()

        var details: [String: String] = ["windowSec": "\(Int(elapsed))"]
        for counter in EnergyCounter.allCases {
            let count = snapshot[counter, default: 0]
            details[counter.rawValue] = "\(count)"
            details[counter.rawValue + "PerMin"] = String(format: "%.1f", Double(count) / elapsed * 60)
        }
        let handshakes = snapshot[.doqHandshake, default: 0]
        if handshakes > 0 {
            details["doqHandshakeAvgMs"] = "\(handshakeMsSum / handshakes)"
        }
        // Gauges (not per-minute counters): the store's flash-write volume for the window
        // (WAL frames × 4 KB page), the process CPU spent, and the device thermal state at
        // flush time. Counts + durations only — never a queried domain (the
        // LavaSecDeviceDebugLog privacy audit).
        details["sqliteWalKB"] = "\(walFrames * 4)"
        details["cpuMs"] = String(format: "%.0f", cpuDeltaMs)
        details["cpuMsPerMin"] = String(format: "%.1f", cpuDeltaMs / elapsed * 60)
        details["thermalState"] = Self.thermalStateLabel(ProcessInfo.processInfo.thermalState)
        LavaSecDeviceDebugLog.append(component: "nrg", event: "nrg-counters", details: details)
        EnergySignpost.event("nrg-window")   // mark each counter window on the Instruments timeline
    }
}
// The QA-only `EnergySignpost` helper lives in `Shared/EnergySignpost.swift` — its own
// dedicated file so the app layer's sole OSLog/os_signpost site (and its reviewed
// mobsfscan `ios_log` suppression) never widens to this file.
#endif
