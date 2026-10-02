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
    static let readTunnelHealthMessage = "read-tunnel-health"
    static let readProtectionStatusMessage = "read-protection-status"
    /// Ask the tunnel for CURRENT chained-upstream runtime truth — a prompt, lightweight read sampled
    /// immediately and about once per second while establishing, then at a lower monitoring cadence
    /// for a live chained session. The NE's `.connected` status flips when the tunnel process starts,
    /// before the WireGuard path is proven, and cannot report a later runner replacement or counter
    /// reset. The JSON ``ChainedHandshakeStatus`` reply supplies that truth without mirror/persist
    /// churn (unlike ``flushTunnelHealthMessage``).
    static let chainedHandshakeStatusMessage = "chained-handshake-status"

    /// Source-compatible namespace for the package-owned prompt handshake wire payload.
    typealias ChainedHandshakeStatus = LavaSecKit.ChainedHandshakeStatus

    /// Ask the tunnel to resolve ONE hostname on the app's behalf.
    ///
    /// Exists to break a deadlock, not to offer the app a general resolver. While the resident
    /// snapshot is fail-closed the tunnel answers every query with the block-all address, so
    /// the app's own `getaddrinfo` returns 0.0.0.0 — and the artifact download that would END
    /// the fail-closed state cannot resolve its source. The repair needs the DNS it is
    /// repairing. The tunnel can still reach the device resolvers (it is what forwards to
    /// them), so it answers this one question directly.
    ///
    /// 🔴 This does NOT change what the tunnel SERVES. The addresses come back over the
    /// provider-message channel to the container app only; they are never encoded into a DNS
    /// response, never written to the utun, and never counted as a served query. Every client
    /// on the device still gets the block-all answer. See INV-DNS-1.
    static let resolveBootstrapHostMessage = "resolve-bootstrap-host"
    /// Payload key carrying the single hostname for ``resolveBootstrapHostMessage``.
    static let resolveBootstrapHostnameKey = "hostname"
    // QA builds place the debug log one level down, inside the group container's `Library/`.
    //
    // Why: `devicectl` can list and copy only the `Library/` subtree of an App Group container —
    // every root-level path fails in BOTH directions (a `copy to` of a brand-new file at the root
    // fails too, which is what proves it is path resolution and not the file being absent). That
    // removed the only cable-side route to this log, and with it the evidence channel the S9
    // device runbook's §2/§4/§5 columns depend on: `data-path-latched`, `nrg-counters`, and the
    // chained-latch observables. Moving the QA log into `Library/` restores a USB pull with no
    // dependence on the in-app bug-report bundle.
    //
    // Scope: QA/DEBUG only, so the shipping layout is untouched. Every consumer derives from this
    // one constant — the writer and rotation lock in `LavaSecDeviceDebugLog`, and the report
    // bundle's reader in `DiagnosticsController` — so the three cannot drift apart, and the
    // rotated/lock siblings stay adjacent to the log wherever it lives.
    // 🔴 THIS PIN USED TO NAME ONLY THE ROTATION TEST, which slices `rotate(_:)`'s body and
    // asserts flock properties — it never reads this constant, the `#if`, or the `Library/`
    // prefix. Deleting the QA branch entirely left the whole suite green while silently killing
    // the cable-side evidence channel this comment is about (sweep, PR #623).
    // pinned: PacketTunnelDNSRuntimeSourceTests.testTheQADeviceDebugLogLivesInTheLibrarySubtree
    // pinned: PacketTunnelDNSRuntimeSourceTests.testDeviceDebugLogRotationIsCrossProcessLocked
    #if DEBUG || LAVA_QA_TOOLS
    static let vpnDebugLogFilename = "Library/vpn-debug-log.jsonl"
    #else
    static let vpnDebugLogFilename = "vpn-debug-log.jsonl"
    #endif
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
    // The "app is in the foreground RIGHT NOW" flag moved to LavaSecKit's
    // `LavaAppForegroundPublication` (same stored key), which pairs it with a wall-clock stamp so the
    // banner posters can age out a crash-stuck assert (Codex review #361).
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
    // QA-only leak-rig positive control (#8). The Admin/QA menu writes an armed nonce + target
    // resolver IP; at chained establishment the tunnel emits ONE cleartext DNS query for
    // `<nonce>.leak-canary.lavasec.invalid` to that resolver on the PHYSICAL path (a deliberate leak
    // the off-device capture must SEE). Inert in Release: the emitter that reads these is compiled out
    // behind `#if DEBUG || LAVA_QA_TOOLS`, so a stray value here does nothing.
    static let leakCanaryArmedNonceKey = "lavasec.qa.leakCanary.armedNonce"
    static let leakCanaryResolverIPKey = "lavasec.qa.leakCanary.resolverIP"
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
    static let protectionLifecycleStateFilename = "protection-lifecycle-state.json"
    static let protectionLifecycleMutationLockFilename = "protection-lifecycle-mutation.lock"
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
    // Terminal cross-process ordering lock for Focus diagnostic event capture versus the user's
    // generation-advancing clear. Kept separate from the long-held focus-switch lock so a synchronous
    // main-thread clear never waits for a cold compile (PR #626).
    static let focusDiagnosticOrderingLockFilename = "focus-diagnostic-ordering.lock"
    // Content-addressed pointer-swap substrate for the shared filter-artifact set
    // (LAV-90 Phase 1). The lock arbitrates writer-vs-writer only; the tunnel reads
    // the pointer-swapped set lock-free. App + tunnel share these strings.
    static let filterArtifactPublishLockFilename = "filter-artifact-publish.lock"
    // Single-flight for the background warm pass. The sidecar warm index is rewritten
    // WHOLESALE (both writes replace the whole file), so two concurrent passes computing
    // from the same prior state end with the later write dropping the earlier run's freshly
    // staged entries — fewer warm artifacts, the opposite of the pass's purpose. Distinct
    // from the publish lock on purpose: that one arbitrates the pointer flip and is held
    // briefly, while this is held across a multi-second compile loop, so sharing it would
    // stall every switch behind a background warm. `flock` is auto-released on process
    // death, so a jetsammed BGTask cannot wedge it (PR #646).
    static let backgroundWarmIndexLockFilename = "background-warm-index.lock"
    static let filterArtifactsDirectoryName = "filter-artifacts"
    static let filterArtifactPointerFilename = "current.json"
    static let customizationLavaGuardLookDefaultsKeyName = "lavasec.customization.lavaGuardLook"
    static let latencyOperationIDOptionKeyName = "lavasec.latency.operationID"

    // Chained upstream (Phase 4). Aliased to the LavaSecKit store so the app (writer) and the
    // tunnel (reader) can never drift on these strings — the same technique the protection
    // store keys above use. The store itself takes a container URL rather than reaching for
    // one, because `LavaSecKit` is an SPM target and this enum is pbxproj-membership source
    // that no package target can see.
    //
    // Which identity's records this build addresses. `group.com.lavasec` is NOT config-scoped
    // — the QA and production builds carry the same App Group entitlement and are installed
    // side by side — so unlike the key half, whose access group project.yml scopes per
    // configuration, the file half needs the separation applied to its NAMES. Without it a QA
    // rotation replaces the generation the production tunnel reads while its key lands in the
    // QA-only access group, and production reports `noPrivateKeyStored` until reconfigured
    // (`ChainedUpstreamStoreIdentity` carries the full account).
    //
    // Selected by the compilation condition rather than a fourth build setting: project.yml's
    // QA configuration is the single place that sets LAVA_QA_TOOLS, and it is the SAME
    // configuration that overrides LAVA_KEYCHAIN_SHARING_GROUP, so the two halves cannot be
    // namespaced apart. A dedicated `LAVA_CHAINED_UPSTREAM_*` setting would be a third
    // identity knob to keep in sync with the other two, which is the divergence hazard
    // `ChainedUpstreamSecretNaming` exists to avoid rather than one to add.
    // pinned: ChainedUpstreamEntitlementSourceTests.testTheFileHalfIsNamespacedByTheSameConfigurationAsTheKeyHalf
    #if LAVA_QA_TOOLS
    static let chainedUpstreamStoreIdentity = ChainedUpstreamStoreIdentity.qa
    #else
    static let chainedUpstreamStoreIdentity = ChainedUpstreamStoreIdentity.production
    #endif
    static var chainedUpstreamConfigurationFilename: String {
        ChainedUpstreamSecretNaming.configurationFilename(for: chainedUpstreamStoreIdentity)
    }
    static var chainedUpstreamWriteLockFilename: String {
        ChainedUpstreamSecretNaming.writeLockFilename(for: chainedUpstreamStoreIdentity)
    }
    static var chainedLifecycleEvidenceLockFilename: String {
        switch chainedUpstreamStoreIdentity {
        case .production: "chained-lifecycle-evidence.lock"
        case .qa: "chained-lifecycle-evidence.qa.lock"
        }
    }

    /// Dedicated marker coordination. This must not share the lifecycle-evidence lock: a
    /// timed-out Keychain worker may remain inside that lock after the caller has moved on, while
    /// the provider still has to publish the terminal automatic-start gate before cancelling.
    static var chainedStartupFailureMarkerLockFilename: String {
        switch chainedUpstreamStoreIdentity {
        case .production: "chained-startup-failure-marker.lock"
        case .qa: "chained-startup-failure-marker.qa.lock"
        }
    }

    /// Durable terminal marker, namespaced with the same chained-store identity as its lock and
    /// upstream configuration. QA and production share the App Group container but must never
    /// gate one another's tunnel starts.
    static var chainedStartupFailureMarkerFilename: String {
        switch chainedUpstreamStoreIdentity {
        case .production: "chained-startup-failure-marker.json"
        case .qa: "chained-startup-failure-marker.qa.json"
        }
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var chainedLifecycleEvidenceLockURL: URL? {
        containerURL?.appendingPathComponent(chainedLifecycleEvidenceLockFilename)
    }

    static var chainedStartupFailureMarkerLockURL: URL? {
        containerURL?.appendingPathComponent(chainedStartupFailureMarkerLockFilename)
    }

    static var chainedStartupFailureMarkerURL: URL? {
        containerURL?.appendingPathComponent(chainedStartupFailureMarkerFilename)
    }

    /// The team-qualified keychain access group the app and the tunnel share for the chained
    /// upstream, or `nil` when this build cannot share keychain items.
    ///
    /// `nil` on an unsigned or local build: `Config/Lava.xcconfig` ships `DEVELOPMENT_TEAM =`
    /// empty so no team ID lives in the repo, and the resolver refuses the resulting
    /// prefix-less string rather than handing back a group nothing is entitled to. The store
    /// is then unconstructible, which is the correct fail-closed outcome — falling back to the
    /// per-bundle default group would put the app's write somewhere the tunnel cannot see it,
    /// and the tunnel reports that as "you never configured this" with no error anywhere.
    ///
    /// Also `nil` in the widget and the App Intents extension: this file is compiled into all
    /// four targets by pbxproj membership, but only the app and the tunnel carry the
    /// `keychain-access-groups` entitlement and the `LavaKeychainSharingGroup` Info.plist key.
    /// Neither of those two has any business with a VPN private key, and least privilege here
    /// is the same argument `Package.swift` makes about not putting a crypto archive in a
    /// process that has no use for it.
    static var chainedUpstreamKeychainAccessGroup: String? {
        ChainedUpstreamKeychainAccessGroup.resolved(
            Bundle.main.object(forInfoDictionaryKey: "LavaKeychainSharingGroup") as? String)
    }

    /// The shared app-group `UserDefaults`, falling back to `.standard` if the
    /// group container is unavailable. Single source so the app, tunnel, intents,
    /// and command service can't drift onto `.standard` by accident.
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    static var securityGateProjectionURL: URL? {
        containerURL.map { SecurityProtectedSurfaceStorage.projectionURL(containerURL: $0) }
    }

    static func protectionNotificationRequestIdentifier(for identifier: String) -> String {
        "\(protectionNotificationRequestIdentifierPrefix)\(identifier)"
    }

    static var protectionNotificationHistoryURL: URL? {
        containerURL?.appendingPathComponent("protection-notification-history.json")
    }

    static func legacyProtectionNotificationHistory(in defaults: UserDefaults = sharedDefaults) -> ProtectionConnectivityNotificationHistory {
        ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: defaults.string(forKey: protectionLastDeliveredNotificationIDDefaultsKeyName),
            lastDeliveredAt: defaults.object(forKey: protectionLastDeliveredNotificationAtDefaultsKeyName) as? Date,
            unresolvedProblemNotificationID: defaults.string(forKey: protectionUnresolvedProblemNotificationIDDefaultsKeyName),
            unresolvedProblemKind: defaults.string(forKey: protectionUnresolvedProblemNotificationKindDefaultsKeyName)
                .flatMap(ProtectionConnectivityNotificationKind.init(rawValue:)))
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
    /// Optional string arguments. Defaulted so every existing construction site — and the
    /// raw-kind decode fallback below — keeps compiling unchanged.
    var payload: [String: String]?

    init(kind: String, operationID: String?, payload: [String: String]? = nil) {
        self.kind = kind
        self.operationID = operationID
        self.payload = payload
    }
}

enum LavaSecProviderMessageCodec {
    private struct Envelope: Codable {
        let kind: String
        let operationID: String?
        // `decodeIfPresent` by virtue of being Optional: an envelope written by an older
        // build has no payload key and must still decode.
        var payload: [String: String]?
    }

    static func encode(kind: String, operationID: String?, payload: [String: String]? = nil) -> Data {
        let envelope = Envelope(kind: kind, operationID: operationID, payload: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data(kind.utf8)
    }

    static func decode(_ data: Data) -> LavaSecProviderMessage? {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return LavaSecProviderMessage(
                kind: envelope.kind, operationID: envelope.operationID, payload: envelope.payload)
        }

        // PRESERVED: a bare kind string. Messages already in flight across an upgrade were
        // written by a build that sent no envelope at all.
        guard let rawKind = String(data: data, encoding: .utf8) else {
            return nil
        }

        return LavaSecProviderMessage(kind: rawKind, operationID: nil)
    }
}

/// The tunnel's answer to ``LavaSecAppGroup/resolveBootstrapHostMessage``.
///
/// Addresses ONLY — deliberately no TTL, no resolver identity, no query metadata. The app
/// re-classifies every address through the same public-scope gate it applies to any resolved
/// host, so a compromised or confused tunnel cannot widen what the app will connect to.
struct LavaSecBootstrapHostResolution: Equatable, Codable {
    var ipv4: [String]
    var ipv6: [String]

    var isEmpty: Bool { ipv4.isEmpty && ipv6.isEmpty }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data?) -> LavaSecBootstrapHostResolution? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(LavaSecBootstrapHostResolution.self, from: data)
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
    //
    // Keep milliseconds for the raw log's human-readable display: the transport backlog and brief
    // stalls this instrumentation explains are often sub-second. Report chronology does NOT parse
    // this settable wall-clock field; `observationOrder` supplies the reboot-scoped monotonic key,
    // while shipped whole-second entries remain compatible as physical-order barriers (PR #582).
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
    /// - Parameter observation: paired wall and monotonic times captured when the event happened.
    ///   Defaults to capture at invocation, which is correct for every synchronous caller.
    ///
    ///   The transport/pressure sinks hop their append off the data-path queues, so stamping
    ///   inside this function recorded when the queued block ran rather than when the event
    ///   occurred — under IO backlog that skews the time and can reorder these entries against
    ///   the synchronously-logged path/DNS/reconnect lines they exist to be correlated with,
    ///   which is the whole value of the telemetry (Codex P2, PR #582).
    static func append(
        component: String, event: String, details: [String: String] = [:],
        observation: DeviceLogObservation = DeviceLogObservationClock.capture()
    ) {
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
        payload["timestamp"] = timestampFormatter.string(from: observation.observedAt)
        // Structural metadata, deliberately not a caller detail or privacy-allowlist key. Assigning
        // nil removes a spoofed detail with this reserved name when the boot UUID is unavailable.
        payload["observationOrder"] = observation.order?.serialized

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
    // Chained tunnel-DNS evidence (S9 battery; phase-3 plan resolved decision 3). These
    // are the numerators and denominator the deferred TCP-retry enablement is gated on,
    // and nothing else in the process can supply them: the outage driver folds a TC
    // answer into `.answered` on purpose (TC is resolver liveness, not failure), and
    // `udpTruncatedResponseCount` is mode-agnostic — in DNS-only mode a truncation is
    // followed by a TCP retry that completes, so the same counter means something
    // different there.
    //
    // TRUNCATION IS TWO POPULATIONS, and the decision needs them apart. The failover loop
    // continues past a TC answer, so a later resolver can return a complete response:
    // that resolution SAW truncation but resolved, and no TCP retry would have helped it.
    // Only the shape where truncation was seen and no resolver ever completed is evidence
    // that the deferred retry is worth building. Counting them as one number inflates the
    // gate by however well failover is already working (Codex, PR #520).
    case chainedDNSResolution           // tunnelled resolutions attempted (the denominator)
    case chainedDNSTruncatedAnswer      // of those, ones that saw a TC answer at all
    case chainedDNSTruncatedUnresolved  // of THOSE, ones no resolver ever completed
    case chainedDNSSilentTimeout        // ...and ones a resolver's SILENCE ended (see below)
    case chainedDNSUnparseableTimeout   // ...and the same, for queries with no name to key
    // Chained DNS fallback (T1) doing work: resolutions whose SERVING resolver address is a
    // member of the session-latched alternative-DNS set. Against `chainedDNSResolution` this reads
    // as the fallback rescue rate — the answer to "is the alternative DNS actually carrying
    // traffic, or is T0 fine". Attributed by ADDRESS MEMBERSHIP, not by "a failover happened"
    // (which mis-counts a backed-off primary and a second-conf-resolver rescue); no query name.
    case chainedDNSFallbackRescue
    // One extra attempt spent on a forwarded resolution that never reached the wire, before it
    // was allowed to answer. Read against `chainedDNSResolution` for "how often is a local refusal
    // being rescued rather than surfacing as a dead page".
    //
    // 🔴 NOT LIFECYCLE-GUARDED, unlike that denominator, and the difference is accepted rather than
    // overlooked. PR #575 moved `chainedDNSFallbackRescue` under the same token guard as its
    // denominator so a teardown boundary could not strand the numerator above it; this one bumps
    // at retry-SCHEDULE time on the resolver pool, where those tokens are not in hand. The skew is
    // bounded at two per resolution and only for resolutions straddling a teardown, so the ratio
    // stays readable — but read it as "retries scheduled", not "retries inside this lifecycle"
    // (Kilo, PR #623).
    case chainedDNSPreWireRetry
    // Chained tunnel-DNS REPLY SHAPE: resolutions in which some resolver answered NOERROR with
    // NO answer records. Split by whether an authority section backs the negative (RFC 2308
    // §2.2), because unsplit the number says nothing — ordinary NODATA is most of DNS (every
    // AAAA for an IPv4-only host is one).
    //
    // DIAGNOSTIC ONLY. `unbacked` means "no answer records and no authority records" and nothing
    // more: RFC 2308 §2.2's type 3 NODATA has exactly that shape and is a legitimate negative,
    // so a climbing unbacked count is a HINT that the VPN's resolver may be completing lookups
    // without resolving them — never a verdict, and nothing in the resolution path may act on it
    // (`TunnelledPlainDNSResolution` records it and fails over on none of it; Codex, PR #589).
    // The shape is still worth counting because it moved NO existing counter: rc8 in the field
    // (build 1787707228, 2026-08-26) held `chainedDNSSilentTimeout` and
    // `chainedDNSFallbackRescue` at 0 with `tunnelDNSAnswered` climbing while every connection
    // on the device failed, and the shape had to be inferred twice from counters that did not
    // move. Counted on EVERY resolution, T1 configured or not — the route with no T1 yet
    // is the one whose capture most needs to say this.
    //
    // Unbacked is a strict subset of empty, structurally (both bumped together below), so the
    // two are never added.
    case chainedDNSEmptyAnswer
    case chainedDNSUnbackedEmptyAnswer

    // THE ADDRESS QUERY IS THE ONE THAT COSTS THE USER A PAGE, and neither counter above can
    // see it. `emptyAnswer(in:)` reads the header alone — answer count, authority count — and
    // never the QUESTION, so an AAAA NODATA for a v4-only host (most of DNS, entirely benign)
    // and an A NODATA for a public name (the client gets no address at all) are one number.
    //
    // Field 2026-08-28, build 1787899086: 230 empty answers across 1266 resolutions, with
    // `chainedDNSUnbackedEmptyAnswer` at 0. Read as benign for that reason — and the reading was
    // an assumption, not a measurement, because the split that would have settled it did not
    // exist. Meanwhile reddit.com resolved and then loaded nothing, on a Wi-Fi with no IPv6, with
    // every other counter healthy. That is exactly the shape the family was added for.
    //
    // NXDOMAIN rides alongside because for an ADDRESS query the two are the same event to the
    // client, and this file's neighbour in `TunnelledPlainDNSResolution` records that the
    // unsolved MagicDNS shape answers public names NXDOMAIN rather than NODATA — counting only
    // the empty case would have missed it.
    case chainedDNSEmptyIPv4AddressAnswer
    case chainedDNSNXDomainIPv4Address

    // ANSWER-SIDE ROUTING CLASS, the fact left after the family above came back empty. The
    // 2026-08-29 capture (build 1787960023) has the resolver answering 39 lookups in the
    // minute before the failure with zero empty A answers, zero A-NXDOMAINs and zero
    // unanswered queries, while pages for names it had just resolved did not load. So the
    // answers existed; what no counter could say is what was IN them.
    //
    // It matters because of the route, not the DNS: chained mode carries `100.64.0.0/10`
    // and the DNS network into the tunnel and sends everything else direct. A public name
    // answered with a CGNAT or RFC1918 address therefore sends that connection somewhere the
    // browser is not expecting — resolves fine, never loads. Membership per resolution, not
    // per address (see `IPv4AnswerAddressClasses`), so one lookup answered `A 1.2.3.4` and
    // `A 100.64.0.5` bumps public AND cgnat exactly once each and the four never sum to
    // something a reader can mistake for an address count.
    //
    // ONLY THE PUBLIC TERM STANDS ALONE. The other three answer "was this address routable for
    // the browser", never "was the NAME a public one", and each has a legitimate reading that
    // lifts it exactly like the poisoning they were added to detect (Codex, PR #619):
    //
    //   - CGNAT: MagicDNS answers TAILNET names from `100.64.0.0/10` correctly, and every device
    //     lookup crosses this path in chained mode, so one `ping myhost` lifts it.
    //   - PRIVATE: a split conf may route an RFC1918 range and place its resolver inside it
    //     (`ChainedTunnelResolverSelectionTests.testSplitSelectsOnlyTheResolversAllowedIPsCovers`
    //     keeps `10.8.0.1` under `10.0.0.0/8`), so an internal name answered `10.x` is correct.
    //   - SPECIAL: a filtering upstream — which is what a chained exit node often is — answers a
    //     name it blocks with `0.0.0.0`, the same convention this app's own block answer uses.
    //
    // The conf's SEARCH DOMAINS are what would separate a tailnet or internal name from a public
    // one, and they are discarded before they reach here: `ChainedTunnelResolverSelection` admits
    // only usable resolver ADDRESSES from `DNS =`. So a non-zero minute in any of the three is a
    // POINTER to the names `domain-history` recorded in that minute, not a verdict on its own.
    //
    // That pairing is not guaranteed either. These counters run unconditionally in a QA build,
    // while the name log is gated on Domain Logs (`keepDomainDiagnostics`) and is cleared when
    // the user turns the setting off, so an archive can carry a header-only CSV beside a climbing
    // count. WITH NO NAMES TO PAIR AGAINST, all three read as UNRESOLVED — not as the benign
    // explanation above, and not as poisoning. Reading them either way from the number alone is
    // how a capture sends the next investigation to the wrong place.
    //
    // Plumbing the search domains through the latch is its own slice — it is what would let these
    // three stand alone.
    case chainedDNSAnswerPublicIPv4Address
    case chainedDNSAnswerCGNATIPv4Address
    case chainedDNSAnswerPrivateIPv4Address
    case chainedDNSAnswerSpecialIPv4Address
    /// A resolution whose well-formed, resolved reply carried at least one AAAA address.
    ///
    /// The IPv6 half the IPv4 classes above cannot express. Without it a v6 answer bumped no
    /// address counter, so the 2026-09-17/19 captures could not tell how much of the traffic was
    /// v6 — part of why the v6-shaped escape went unseen. Membership, never an address.
    case chainedDNSAnswerIPv6Address
}

final class EnergyCounters: @unchecked Sendable {
    static let shared = EnergyCounters()

    private let lock = NSLock()
    private var isActive = false
    private var counts: [EnergyCounter: Int] = [:]
    private var doqHandshakeMsSum = 0
    private var sqliteWALFrames: Int64 = 0
    /// Distinct query names (the driver's own opaque keys) that timed out this window,
    /// bounded by ``chainedDNSDistinctNameSlots``. Cleared with the counters at each flush
    /// AND on ``activate()``, so neither a busy window nor a previous tunnel session can
    /// leave a saturated set behind for the next one to be measured against.
    private var chainedDNSSilentTimeoutNameKeys: Set<UInt64> = []
    /// The resolver port registry's own cumulative tallies, stamped for the next flush.
    ///
    /// LEVELS, not counts, and that is why they live here rather than in `counts`: they are the
    /// registry's running totals, so a `+=` would sum a level with itself every tick and grow
    /// quadratically. They also survive a flush, because the registry does.
    private var chainedResolverPortRefusedAtCapacity = 0
    private var chainedResolverPortRefusedAtGraceCapacity = 0
    private var chainedResolverPortEvictedWhileLive = 0
    private var chainedResolverPortLiveClaims = 0
    private var lastCPUTimeMs = 0.0
    private var thermalObserver: (any NSObjectProtocol)?
    private var windowStartedAt = Date()
    private var lastFlushAt = Date()
    private static let flushInterval: TimeInterval = 60
    /// How many distinct timed-out names one window distinguishes before saturating.
    ///
    /// Small on purpose. The question decision 3 asks is "one domain or many", so the
    /// useful resolution is near the bottom of the range: 1 is the trap, 2+ is a resolver
    /// problem, and 8 gives room to see a spread without the count becoming a set an
    /// attacker's subdomains can grow. A saturated window reports the cap and is read as
    /// "at least this many", which is exactly what the rate needs.
    private static let chainedDNSDistinctNameSlots = 8

    /// What a resolution's truncation, if any, cost it — derived once at the call site
    /// from the result, because the OBSERVATION deliberately cannot tell: a TC answer
    /// classifies `.answered` (TC is resolver liveness, the trap decision 3 exists to
    /// name), so the driver's answered count folds truncations in with plain successes.
    enum ChainedDNSTruncation {
        case notSeen
        /// Saw a TC answer, and a later resolver in the route still returned a complete
        /// response. The failover already handled it; a TCP retry would have added
        /// nothing, so this must not count toward the retry gate.
        case rescuedByFailover
        /// Saw a TC answer and no resolver ever completed. THIS is the shape the deferred
        /// retry would have rescued, and the only one that should move the gate.
        case unresolved
    }

    /// What SHAPE of empty NOERROR, if any, a resolution saw — the resolution decides it
    /// (`TunnelledPlainDNSResolution.Verdict`), because the split is RFC 2308 §2.2's and needs
    /// the wire message, which no counter here ever sees.
    enum ChainedDNSEmptyAnswer {
        case notSeen
        /// NOERROR with no answers and a non-empty authority section (RFC 2308 type 1 / type 2).
        case backed
        /// NOERROR with no answers and an empty authority section (RFC 2308 type 3). Legitimate,
        /// merely uninformative — the count is a hint to a human reading a capture, not a verdict.
        case unbacked
    }

    /// What T0 said about an IPv4 ADDRESS query that came back with no address — the
    /// resolution decides it (`TunnelledPlainDNSResolution.Verdict.ipv4AddressNegative`), because
    /// the split needs the QUESTION and no counter here ever sees one.
    enum ChainedDNSIPv4AddressNegative {
        case none
        case emptyAnswer
        case nameDoesNotExist
    }

    /// Which routing classes an IPv4 ADDRESS answer carried — decided by the resolution
    /// (`TunnelledPlainDNSResolution.Verdict.ipv4AddressClasses`), because classifying needs
    /// the answer bytes and no counter here ever sees one. Membership, so the four flags are
    /// independent and a single resolution can set several.
    struct ChainedDNSIPv4AddressClasses {
        var containsPublicRoutable = false
        var containsCarrierGradeNAT = false
        var containsPrivateUse = false
        var containsSpecialUse = false

        static let none = ChainedDNSIPv4AddressClasses()
    }

    /// A resolution that ended with a resolver's SILENCE — at least one selected resolver
    /// timed out and none completed — split by whether there is a name to attribute it to.
    /// The split is load-bearing, not bookkeeping — see
    /// ``recordChainedDNSResolution(truncation:timeout:emptyAnswer:)``.
    ///
    /// "At least one", NOT "every", and the distinction is deliberate. A resolution where one
    /// resolver refused locally (`.sendFailed`, `.socketUnavailable`) and another timed out
    /// still belongs here: a query WAS sent and its budget elapsed, which is the evidence
    /// this rate is about, and a sibling's local failure does not erase it — the same
    /// reasoning `TunnelledPlainDNSResolution` uses to classify that shape `.unanswered`
    /// (pinned by `testAMixedLocalFailureAndTimeoutIsStillUnanswered`).
    ///
    /// A resolution where EVERY attempt failed locally is already excluded, and not by this
    /// type: no timeout means no `.unanswered` observation, so nothing reaches here. The
    /// earlier wording said "every selected resolver stayed silent", which described neither
    /// the computation nor the intent (Codex, PR #520).
    enum ChainedDNSTimeout {
        case named(nameKey: UInt64)
        case unparseableQuery
    }

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
        // Per-session like every count above it, and missed when this set was added: a
        // stop/start inside one un-killed extension process would otherwise carry the
        // previous session's distinct names into the next session's first window, where
        // a single new timeout could be reported against a set already saturated by a
        // session that has ended — the ceiling read as a measurement (Codex, Kilo, #520).
        chainedDNSSilentTimeoutNameKeys.removeAll(keepingCapacity: true)
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

    /// The process's physical memory footprint, read from the same ledger jetsam judges.
    ///
    /// ONE syscall per 60 s flush, and the peak comes from the kernel rather than from sampling.
    /// A sampling loop would be both less accurate — the spike that kills a process lands between
    /// samples — and a cost paid on the DNS-serving path that `INV-MEM-1` keeps clear.
    ///
    /// The peak field arrives only on `TASK_VM_INFO_REV1` and later, so its presence is decided by
    /// the count the kernel wrote back, never assumed. Reading it unconditionally would hand a log
    /// line whatever happened to sit past the end of a short struct.
    private static func processMemoryFootprint() -> TunnelMemoryFootprint? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // The bound is computed from the FIELD, not from `TASK_VM_INFO_REV1_COUNT` — that is a C
        // macro Swift does not import, and hardcoding its value would rot silently the next time
        // the struct grows. `count` is what the kernel actually wrote back, in `natural_t` units.
        let peakFieldEnd = MemoryLayout<task_vm_info_data_t>
            .offset(of: \.ledger_phys_footprint_peak)
            .map { ($0 + MemoryLayout<UInt64>.size) / MemoryLayout<natural_t>.size }
        let peak: UInt64? = peakFieldEnd.flatMap {
            count >= mach_msg_type_number_t($0) ? UInt64(info.ledger_phys_footprint_peak) : nil
        }
        return TunnelMemoryFootprint(bytes: UInt64(info.phys_footprint), peakBytes: peak)
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

    // Record EVERY term of ONE tunnelled resolution — denominator, truncation, timeout —
    // under ONE lock.
    //
    // ONE CALL IS THE POINT, not a convenience. A rate is only computable if its terms
    // land in the same 60 s window, and the terms are not available at the same moment:
    // the denominator is known when the resolution starts, the outcome only after a
    // failover loop that spends a full UDP timeout per silent resolver. Counting the
    // denominator at entry (the first shape of this code) let a resolution that straddled
    // a flush emit its denominator in one `nrg-counters` line and its numerator in the
    // next — so a window could report a numerator larger than its own denominator, or a
    // denominator with no outcome, and the per-window rates were not computable at all
    // (Codex, PR #520). Every caller therefore records at its EXIT, and every exit
    // records: a resolution refused before the wire is a resolution with no outcome terms.
    //
    // Passing the terms as values rather than as separate calls is what keeps them in one
    // window BY CONSTRUCTION — two calls under two locks reintroduce the same straddle in
    // miniature, since a flush can land between them.
    //
    // The distinct-name figure moves under that same lock for the older reason the DoQ
    // pair below does: a concurrent flush must not snapshot a count without it.
    //
    // The distinct-name figure is what makes the rate answerable. Resolved decision 3
    // turns on telling two situations apart that produce the same timeout count: ONE
    // fragmenting or OPT-ignoring domain retried by a browser (the trap — must not arm
    // anything, and must not motivate a TCP retry either), versus a resolver failing
    // across the board. The outage driver cannot answer it: its own distinct-name set
    // deliberately stops growing at 2, because 2 is the only count its declaration
    // depends on and an unbounded set is a memory surface a chosen-traffic attacker
    // fills for free (`INV-MEM-1`).
    //
    // So this keeps its own set, SATURATING at a fixed slot count for the same reason —
    // fixed residency, no growth an attacker can steer, and no name ever held: the caller
    // passes the driver's own opaque `nameKey` hash, so "distinct" means here exactly
    // what it means there, and the debug-log privacy audit (no queried domains, ever) is
    // satisfied by construction rather than by redaction.
    //
    // AN UNPARSEABLE QUERY IS NOT A NAMELESS DOMAIN. Its timeout carries no name to key,
    // and folding every such query into one shared key would manufacture precisely the
    // shape this measurement exists to detect — many timeouts on one apparent distinct
    // name is the "one fragmenting domain" signature (Codex, PR #520). So it gets its own
    // counter, out of the per-domain rate, matching the report path in the provider, which
    // drops the same observations because they are outside the evidence stream the
    // question is scoped to.
    //
    // AND IT SHOULD READ ZERO. The serving path parse-gates before dispatch — an
    // unparseable payload is answered with a parse failure and never reaches resolution —
    // so a nameless timeout is not something chosen traffic can produce here. That makes
    // this counter a CANARY rather than a rate: non-zero in a battery log means a query
    // reached the tunnelled executor without a parseable question, which is a finding in
    // itself. It is counted rather than ignored precisely because the resolution type can
    // represent the case (`Observation.unanswered` carries `String?`) and silence about an
    // impossible state is how the state stops being impossible.
    /// The resolver port registry's cumulative pressure tallies, stamped for the next flush.
    ///
    /// LEVELS, not counts — these are the registry's own running totals, so they are STORED rather
    /// than accumulated. Emitted beside the per-window counters with no `PerMin`, because a rate
    /// over a cumulative level is meaningless. Difference two captures to get a window.
    func recordChainedResolverPortPressure(
        refusedAtCapacity: Int, refusedAtGraceCapacity: Int, evictedWhileLive: Int, liveClaims: Int
    ) {
        lock.lock()
        if isActive {
            chainedResolverPortRefusedAtCapacity = refusedAtCapacity
            chainedResolverPortRefusedAtGraceCapacity = refusedAtGraceCapacity
            chainedResolverPortEvictedWhileLive = evictedWhileLive
            chainedResolverPortLiveClaims = liveClaims
        }
        lock.unlock()
    }

    /// One extra attempt spent on a resolution that had not reached the wire.
    func recordChainedDNSPreWireRetry() {
        lock.lock()
        if isActive {
            counts[.chainedDNSPreWireRetry, default: 0] += 1
        }
        lock.unlock()
    }

    func recordChainedDNSResolution(
        truncation: ChainedDNSTruncation, timeout: ChainedDNSTimeout?,
        emptyAnswer: ChainedDNSEmptyAnswer = .notSeen,
        ipv4AddressNegative: ChainedDNSIPv4AddressNegative = .none,
        ipv4AddressClasses: ChainedDNSIPv4AddressClasses = .none,
        hasIPv6AnswerAddress: Bool = false
    ) {
        lock.lock()
        if isActive {
            counts[.chainedDNSResolution, default: 0] += 1
            switch emptyAnswer {
            case .notSeen:
                break
            case .backed:
                counts[.chainedDNSEmptyAnswer, default: 0] += 1
            case .unbacked:
                // Deliberately BOTH, the same containment the truncation arm makes structural:
                // unbacked is a subset of empty, and bumping only the subset is what lets a later
                // reader add the two together and double-count one resolution.
                counts[.chainedDNSEmptyAnswer, default: 0] += 1
                counts[.chainedDNSUnbackedEmptyAnswer, default: 0] += 1
            }
            switch ipv4AddressNegative {
            case .none:
                break
            case .emptyAnswer:
                counts[.chainedDNSEmptyIPv4AddressAnswer, default: 0] += 1
            case .nameDoesNotExist:
                counts[.chainedDNSNXDomainIPv4Address, default: 0] += 1
            }
            // Independent, not a switch: the classes are membership flags and one answer can
            // legitimately carry several. A resolution that carried none of them (not an A
            // query, or an answer with no address records) bumps nothing here — the negative
            // family above is what describes that case.
            if ipv4AddressClasses.containsPublicRoutable {
                counts[.chainedDNSAnswerPublicIPv4Address, default: 0] += 1
            }
            if ipv4AddressClasses.containsCarrierGradeNAT {
                counts[.chainedDNSAnswerCGNATIPv4Address, default: 0] += 1
            }
            if ipv4AddressClasses.containsPrivateUse {
                counts[.chainedDNSAnswerPrivateIPv4Address, default: 0] += 1
            }
            if ipv4AddressClasses.containsSpecialUse {
                counts[.chainedDNSAnswerSpecialIPv4Address, default: 0] += 1
            }
            if hasIPv6AnswerAddress {
                counts[.chainedDNSAnswerIPv6Address, default: 0] += 1
            }
            switch truncation {
            case .notSeen:
                break
            case .rescuedByFailover:
                counts[.chainedDNSTruncatedAnswer, default: 0] += 1
            case .unresolved:
                // Deliberately BOTH: unresolved is a subset of "saw a TC answer", and
                // making the containment structural here is what stops a later reader
                // adding the two together and double-counting the same resolution.
                counts[.chainedDNSTruncatedAnswer, default: 0] += 1
                counts[.chainedDNSTruncatedUnresolved, default: 0] += 1
            }
            switch timeout {
            case nil:
                break
            case .named(let nameKey):
                counts[.chainedDNSSilentTimeout, default: 0] += 1
                if chainedDNSSilentTimeoutNameKeys.count < Self.chainedDNSDistinctNameSlots {
                    chainedDNSSilentTimeoutNameKeys.insert(nameKey)
                }
            case .unparseableQuery:
                counts[.chainedDNSUnparseableTimeout, default: 0] += 1
            }
        }
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
        let chainedTimeoutNames = chainedDNSSilentTimeoutNameKeys.count
        let portRefusedAtCapacity = chainedResolverPortRefusedAtCapacity
        let portRefusedAtGraceCapacity = chainedResolverPortRefusedAtGraceCapacity
        let portEvictedWhileLive = chainedResolverPortEvictedWhileLive
        let portLiveClaims = chainedResolverPortLiveClaims
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
        chainedDNSSilentTimeoutNameKeys.removeAll(keepingCapacity: true)
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
        // Distinct timed-out names, saturating at the slot count — read as "at least this
        // many". Emitted only when there were timeouts at all, so a quiet window does not
        // carry a zero that reads like a measurement.
        if snapshot[.chainedDNSSilentTimeout, default: 0] > 0 {
            details["chainedDNSSilentTimeoutNames"] = "\(chainedTimeoutNames)"
            details["chainedDNSSilentTimeoutNamesSaturated"] =
                "\(chainedTimeoutNames >= Self.chainedDNSDistinctNameSlots)"
        }
        // THE PORT REGISTRY'S OWN PRESSURE, which was counted and never read: `refusedAtCapacity`
        // existed only for tests, so on device a capacity refusal and a genuine socket failure were
        // the same silent `.socketUnavailable`. Reading it here is what identified the cause.
        //
        // LEVELS, so no `PerMin`: difference two captures to get a window.
        // - `refusedAtCapacity` nonzero means SIXTEEN SIMULTANEOUSLY-LIVE claims, i.e. the
        //   concurrency argument behind `capacity` has broken. A bug report, not a capacity signal.
        // - `refusedAtGraceCapacity` nonzero means the grace backstop fired, which needs a release
        //   rate ~200x the observed one. It says `graceCapacity` is mis-sized, not that the device
        //   is unhealthy.
        // - `liveClaims` is the occupancy the bound is measured against, so a reader sees the
        //   headroom instead of inferring it from refusals.
        // - `evictedWhileLive` is a provable zero, retained as a regression tripwire for the
        //   evict-oldest policy the refusal replaced.
        details["chainedResolverPortRefusedAtCapacity"] = "\(portRefusedAtCapacity)"
        details["chainedResolverPortRefusedAtGraceCapacity"] = "\(portRefusedAtGraceCapacity)"
        details["chainedResolverPortEvictedWhileLive"] = "\(portEvictedWhileLive)"
        details["chainedResolverPortLiveClaims"] = "\(portLiveClaims)"
        details["sqliteWalKB"] = "\(walFrames * 4)"
        // MEMORY, because a jetsam kill cannot log its own cause — the process is gone. The peak
        // is what gets a process killed, so it is reported alongside the instantaneous reading and
        // is what the percentage is taken from (PR #578).
        if let footprint = Self.processMemoryFootprint() {
            details["footprintMB"] = "\(footprint.megabytes)"
            details["footprintPeakMB"] = footprint.peakMegabytes.map { "\($0)" } ?? "nil"
            details["footprintPctOfCeiling"] = "\(footprint.percentOfReferenceCeiling)"
        }
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
