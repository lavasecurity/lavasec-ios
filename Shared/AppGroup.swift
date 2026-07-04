import Foundation
import LavaSecCore

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
    static let protectionNotificationRouteUserInfoKey = "lavaRoute"
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
    static let appForegroundActiveDefaultsKey = "lavasec.app.foregroundActive"
    static let protectionNotificationKindUserInfoKey = "lavaNotificationKind"
    static let protectionNotificationIDUserInfoKey = "lavaNotificationID"
    static let protectionLastDeliveredNotificationIDDefaultsKey = "lavasec.protection.lastDeliveredNotificationID"
    static let protectionLastDeliveredNotificationAtDefaultsKey = "lavasec.protection.lastDeliveredNotificationAt"
    static let protectionUnresolvedProblemNotificationIDDefaultsKey = "lavasec.protection.unresolvedProblemNotificationID"
    static let protectionUnresolvedProblemNotificationKindDefaultsKey = "lavasec.protection.unresolvedProblemNotificationKind"
    static let protectionNotificationKindSchemaVersionDefaultsKey = "lavasec.protection.notificationKindSchemaVersion"
    // Written by the app only after `saveToPreferences` confirms Connect-On-Demand
    // is armed/disarmed, and read by the tunnel to gate self-reconnect: a self-
    // cancel only recovers if on-demand will bring the tunnel back, and the app
    // persists `protectionEnabled = true` even when arming on-demand fails.
    static let protectionOnDemandConfirmedEnabledDefaultsKey = "lavasec.protection.onDemandConfirmedEnabled"
    // Deadline (Double, timeIntervalSinceReferenceDate) marking a Dynamic Island
    // Restart as in progress. Written by the Restart command, read by the app's
    // status reconcile so it reports `.restarting` (instead of clobbering the
    // transient with `.on`/end via the status notifications the restart emits) and
    // so a second concurrent Restart tap is rejected. Stored as a deadline so a
    // killed background intent window auto-clears it.
    static let protectionRestartInFlightUntilDefaultsKey = "lavasec.protection.restartInFlightUntil"
    // The tunnel persists its recent self-reconnect attempt timestamps ([Double] epoch seconds)
    // here for the cooldown/cap policy. Shared so the app can READ the self-reconnect timeline for
    // a bug report's incident summary (LAV-94 B) without touching the tunnel's frozen recovery
    // path. The tunnel's own `selfReconnectAttemptsDefaultsKey` literal is locked to this value by
    // a source test (PacketTunnelDNSRuntimeSourceTests) so the two can never drift.
    static let selfReconnectAttemptTimesDefaultsKey = "tunnel.selfReconnectAttemptTimes"
    // Durable self-reconnect GAP evidence (LAV-92/93 observability). The attempt store above
    // forgets BY DESIGN (productive credit deletes the recovered attempt; the report prunes to
    // the 600 s policy window), so these carry the field-visible record instead: GapStartedAt
    // is stamped at teardown commit; GapEndedAt at the NEXT tunnel launch (the process is
    // serving again — the honest Guard-off window, however long the relaunch took); GapCount
    // is the cumulative committed-teardown count. Written by the tunnel only (epoch seconds /
    // integer); the app READS them into the bug report's incident summary.
    static let selfReconnectGapStartedAtDefaultsKey = "tunnel.selfReconnectGapStartedAt"
    static let selfReconnectGapEndedAtDefaultsKey = "tunnel.selfReconnectGapEndedAt"
    static let selfReconnectGapCountDefaultsKey = "tunnel.selfReconnectGapCount"
    // Aliased to the LavaSecCore stores so the app, tunnel, intents, and the
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
    static let customizationLavaGuardLookDefaultsKey = "lavasec.customization.lavaGuardLook"
    static let latencyOperationIDOptionKey = "lavasec.latency.operationID"

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
                schemaVersion: protectionNotificationKindSchemaVersionDefaultsKey,
                unresolvedProblemKind: protectionUnresolvedProblemNotificationKindDefaultsKey
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

    static func append(component: String, event: String, details: [String: String] = [:]) {
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
