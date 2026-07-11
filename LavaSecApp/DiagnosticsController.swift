import CryptoKit
import DeviceCheck
import Foundation
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices
import SwiftUI

// The diagnostics + bug-report/rage-shake feature, peeled out of AppViewModel (Phase D4,
// lavasec-infra plans/2026-07-07-ios-modularization-scaffolding-plan.md): the
// DiagnosticsStore read/prune lifecycle (refreshDiagnostics + its read gate and the
// deferred-prune flag), the local-log clear flows (including the clear-all privacy
// contract and the incident-ledger / device-debug-log / gap-marker wipes), the
// keep-counts/keep-history preference setters, the bug-report draft lifecycle + send
// state machine (submit + App Attest), and the rage-shake routing. The hub
// (AppViewModel) remains the owner of the configuration, tunnel messaging, VPN status,
// the network-activity log, and LavaGuard progress — this controller reaches those only
// through the narrow `DiagnosticsHubBridging` surface below, mirroring the
// scoped-controller pattern of BackupController / LavaSecurityPlusController /
// AccountController. The two wide-hub-state ASSEMBLY functions deliberately stay
// hub-side (bridge-width judgement): the bug-report bundle assembly is the single
// bridge method `makeBugReportBundle(context:snapshot:...)` this controller calls, and
// `makeLocalLogExportArchive` stays a hub method that calls back into this controller
// for the diagnostics refresh + store + debug-log read it owns.

enum BugReportSendState: Equatable {
    case idle
    case sending
    case sent(reportID: String)
    case failed(message: String)

    var isSending: Bool {
        if case .sending = self {
            return true
        }

        return false
    }
}

private struct BugReportSubmitResponse: Decodable {
    let reportID: String

    private enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
    }
}

private struct BugReportSubmissionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

// A 429 is terminal: it must NOT fail over to the fallback endpoint (both share
// the same per-IP limiter, and failing over would either bypass the throttle if
// they ever diverge or replace the friendly copy with the fallback's raw error).
// Thrown inside the per-endpoint loop and rethrown by a dedicated catch.
private struct BugReportRateLimitedError: Error {}

// The Apple App Attest headers attached to a bug-report submit. `keyId` is the
// base64 key identifier from DCAppAttestService (the server base64-decodes it to
// the 32-byte SHA256 of the attested public key); `attestationBase64` is the
// base64 CBOR attestation object; `challenge` is the one-time token we attested
// over. Server side: backend/worker/src/app-attest.ts.
private struct AppAttestHeaders {
    let challenge: String
    let keyId: String
    let attestationBase64: String

    func apply(to request: inout URLRequest) {
        request.setValue(challenge, forHTTPHeaderField: "X-Lava-Attest-Challenge")
        request.setValue(keyId, forHTTPHeaderField: "X-Lava-Attest-Key-Id")
        request.setValue(attestationBase64, forHTTPHeaderField: "X-Lava-Attest-Object")
    }
}

private enum AppAttestClient {
    // False on the Simulator and on hardware without the Secure Enclave; callers
    // must degrade gracefully (submit unattested) rather than block the user.
    static var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    // Generate a fresh hardware-backed key and attest it over the server
    // challenge. We attest per submission (a new key each time) rather than
    // registering a key and asserting against it, so nothing device-linked is
    // stored server-side. Returns nil on any failure.
    //
    // Replay hardening: the attestation is bound to BOTH the one-time challenge and
    // SHA256(the exact request body) via clientDataHash, so a captured attestation
    // cannot be replayed against a different report body. The server recomputes the
    // identical clientDataHash — keep the two in lockstep (backend/worker/src/app-attest.ts).
    //   clientDataHash = SHA256( utf8(challenge) ‖ bodyHash ), bodyHash = SHA256(body)
    static func attest(challenge: String, bodyHash: Data) async -> AppAttestHeaders? {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            return nil
        }
        do {
            let keyId = try await service.generateKey()
            var clientData = Data(challenge.utf8)
            clientData.append(bodyHash)
            let clientDataHash = Data(SHA256.hash(data: clientData))
            let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            return AppAttestHeaders(
                challenge: challenge,
                keyId: keyId,
                attestationBase64: attestation.base64EncodedString()
            )
        } catch {
            return nil
        }
    }
}

/// The narrow hub surface the diagnostics controller depends on (Phase D4). Everything
/// the diagnostics/bug-report cluster needs from AppViewModel and nothing else, so the
/// hub stays the owner of the shared state:
///
/// - **Configuration reads/writes**: `keepsDomainDiagnostics`/`keepsFilteringCounts`
///   mirror the two config flags the store lifecycle branches on;
///   `persistKeep*Flag` are the write + persist-only funnels for the two
///   diagnostics-coupled preference setters (the hub keeps the network-activity and
///   LavaGuard variants wholesale — they touch only hub state).
/// - **File-ownership signal**: `isProtectionStopPending` classifies the live
///   `vpnStatus` so `refreshDiagnostics` knows when the tunnel owns diagnostics.json
///   (UX-4/PST-3 — see the ownership comment there).
/// - **Tunnel messaging + user surface**: `sendTunnelMessage` relays the clears'
///   coordination messages over the hub-owned provider-message channel;
///   `presentVPNMessage` surfaces clear failures on the hub's banner.
/// - **Cross-feature clears**: the clear-all privacy contract also wipes the
///   hub-owned network-activity log and LavaGuard progress.
/// - **Report refresh + capture**: `refreshReports` refreshes the three report
///   surfaces (this controller's diagnostics + the hub's tunnel health and network
///   activity); `currentFilterSnapshot` captures the compiled snapshot for the
///   bug-report inputs; `refreshLavaGuardProgressFromDiagnostics` lets the hub
///   re-derive LavaGuard progress right after a fresh store load, in the exact
///   pre-peel slot.
/// - **Bundle assembly**: `makeBugReportBundle(context:inputs:)` is the wide-hub-state
///   SNAPSHOT kept hub-side by design (bridge-width judgement) — this controller
///   passes in everything it owns (`BugReportBundleInputs`: the captured heavy inputs
///   plus the live local-observability reads) and the hub captures its own state.
@MainActor
protocol DiagnosticsHubBridging: AnyObject {
    var keepsDomainDiagnostics: Bool { get }
    var keepsFilteringCounts: Bool { get }
    var isProtectionStopPending: Bool { get }
    var isAccountDeveloper: Bool { get }
    func persistKeepFilteringCountsFlag(_ keepFilteringCounts: Bool) throws
    func persistKeepDomainDiagnosticsFlag(_ keepDomainDiagnostics: Bool) throws
    func sendTunnelMessage(_ message: String) async
    func presentVPNMessage(_ message: String, isError: Bool)
    @discardableResult func clearNetworkActivityLog(notifyTunnel: Bool) -> Bool
    @discardableResult func clearLavaGuardProgress() -> Bool
    func refreshReports()
    func refreshLavaGuardProgressFromDiagnostics()
    func currentFilterSnapshot() -> FilterSnapshot
    func makeBugReportBundle(
        context: BugReportContext,
        inputs: BugReportBundleInputs
    ) -> BugReportBundle
}

/// Everything the diagnostics controller owns that the hub-side bug-report bundle
/// ASSEMBLY needs (Phase D4 seam): the heavy inputs captured once per
/// `prepareBugReport` (UR-5 reuse) plus the live local-observability reads the
/// pre-peel assembly performed inline while building the bundle.
struct BugReportBundleInputs {
    let snapshot: FilterSnapshot
    let debugLogEntries: [BugReportDebugLogEntry]
    let selfReconnectTimes: [Date]
    let diagnostics: DiagnosticsStore
    let selfReconnectGap: SelfReconnectGapRecord?
    let recentIncidents: [IncidentLedgerRecord]
}

@MainActor
final class DiagnosticsController: ObservableObject {
    // Deliberately NOT private(set) (matching the pre-peel hub property): the hub still
    // WRITES this store from its own paths — `synchronizeLocalProtectionUptime` mirrors
    // the uptime-marker store it loads/saves, and `recordDemo` appends a demo decision —
    // and the hub owns this controller, so those writes stay hub→controller direct
    // rather than widening the bridge.
    @Published var diagnostics = DiagnosticsStore()
    @Published var rageShakeDestination: RageShakeDestination?
    @Published var pendingRageShakeConfirmation: RageShakeDestination?
    @Published private(set) var bugReportDraft: BugReportBundle?
    @Published private(set) var bugReportSendState: BugReportSendState = .idle

    private var diagnosticsReadGate = FileModificationReadGate()
    // A fine-grained prune was performed in memory but could NOT be written because the tunnel then
    // owned diagnostics.json (stop-pending). Persist it on a later refresh once the app owns the file
    // again, or the expired rows linger on disk until an unrelated write (Codex #225 / UX-4).
    private var diagnosticsPrunePersistDeferred = false

    // The hub outlives this controller (AppViewModel owns it strongly), so an unowned
    // back-reference avoids a retain cycle without weak-optional noise on every call.
    private unowned let hub: any DiagnosticsHubBridging

    init(hub: any DiagnosticsHubBridging) {
        self.hub = hub
    }

    // MARK: - Derived state

    var blockRateText: String {
        diagnostics.summary.blockRate.formatted(.percent.precision(.fractionLength(0)))
    }

    var activityDigestTitle: String {
        let blocked = diagnostics.summary.blockedCount
        guard blocked > 0 else {
            return "Nothing blocked yet today"
        }

        return (blocked == 1 ? "Lava blocked %@ domain today" : "Lava blocked %@ domains today").lavaLocalizedFormat(blocked.formatted())
    }

    var activityDigestSubtitle: String {
        let allowed = diagnostics.summary.allowedCount
        guard diagnostics.summary.totalCount > 0 else {
            return "Once protection sees DNS activity, Lava will summarize it here."
        }

        return "\(allowed.formatted()) allowed locally. All local logs stay on this phone."
    }

    /// Glanceable stat under the Guard "What Lava has caught" row — how many
    /// domains Lava has blocked on this phone today.
    var guardActivityRowStat: String {
        let blocked = diagnostics.summary.blockedCount
        guard blocked > 0 else {
            return "Nothing blocked yet today"
        }

        let percent = diagnostics.summary.blockRate.formatted(
            .percent.precision(.fractionLength(0))
        )
        return "%@ blocked today".lavaLocalizedFormat("\(blocked.formatted()) (\(percent))")
    }

    // MARK: - Rage shake

    var canOpenPhoneQAFromRageShake: Bool {
        #if DEBUG || LAVA_QA_TOOLS
        return hub.isAccountDeveloper
        #else
        return false
        #endif
    }

    func handleRageShake() {
        let destination = RageShakeRouter.destination(allowsAdminQA: canOpenPhoneQAFromRageShake)
        if RageShakeRouter.requiresFeedbackConfirmation(for: destination) {
            pendingRageShakeConfirmation = destination
        } else {
            rageShakeDestination = destination
        }
    }

    func confirmRageShakeFeedback() {
        guard let destination = pendingRageShakeConfirmation else {
            return
        }
        pendingRageShakeConfirmation = nil
        // Let the confirmation alert finish dismissing before presenting the
        // sheet; presenting in the same runloop tick can drop it. Mirrors the
        // phone-QA -> bug-report hand-off in RootView.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.pendingRageShakeConfirmation == nil else {
                // A fresh shake re-armed the confirmation while we waited; let
                // that newer gesture win instead of stacking a sheet under it.
                return
            }
            self.rageShakeDestination = destination
        }
    }

    func cancelRageShakeFeedback() {
        pendingRageShakeConfirmation = nil
    }

    func dismissRageShakeDestination() {
        rageShakeDestination = nil
    }

    // MARK: - Diagnostics & local log export

    func clearDiagnostics() {
        clearAllLocalLogs()
    }

    /// Returns whether the clear durably persisted. A write failure is caught here (surfacing an
    /// error banner + failure haptic) rather than thrown, so callers that need to confirm the clear
    /// to the user — e.g. a VoiceOver announcement — must gate on this result, not assume success.
    @discardableResult
    func clearDomainHistory() -> Bool {
        // One timestamp for both the store's applied-marker and the control request, so
        // the tunnel's force-apply gate reads `requestedAt > marker` = false (PST-1).
        let clearedAt = Date()
        diagnostics.clearDomainHistory(clearedAt: clearedAt)
        clearDNSEventLogHistory(at: clearedAt)

        do {
            try writeDiagnosticsClearControl(clearDomainHistory: true, at: clearedAt)
            try persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            // Strong local so the fire-and-forget notify keeps the hub alive exactly as the
            // pre-peel `Task { await self.sendTunnelMessage(…) }` (self = the hub) did.
            let hub = self.hub
            Task {
                await hub.sendTunnelMessage(LavaSecAppGroup.clearDiagnosticsMessage)
            }
            ProtectionHapticFeedback.play(.actionSucceeded)
            return true
        } catch {
            hub.presentVPNMessage(
                "Could not clear local history: %@".lavaLocalizedFormat(error.localizedDescription),
                isError: true
            )
            ProtectionHapticFeedback.play(.actionFailed)
            return false
        }
    }

    /// Returns whether the clear durably persisted (see `clearDomainHistory`).
    @discardableResult
    func clearLocalFilteringCounts() -> Bool {
        let clearedAt = Date()
        diagnostics.clearFilteringCounts(startedAt: clearedAt)

        do {
            try writeDiagnosticsClearControl(clearFilteringCounts: true, at: clearedAt)
            try persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            // Strong local: see clearDomainHistory.
            let hub = self.hub
            Task {
                await hub.sendTunnelMessage(LavaSecAppGroup.clearFilteringCountsMessage)
            }
            ProtectionHapticFeedback.play(.actionSucceeded)
            return true
        } catch {
            hub.presentVPNMessage(
                "Could not clear local filtering counts: %@".lavaLocalizedFormat(error.localizedDescription),
                isError: true
            )
            ProtectionHapticFeedback.play(.actionFailed)
            return false
        }
    }

    /// Returns whether the primary diagnostics clear durably persisted (see `clearDomainHistory`).
    @discardableResult
    func clearAllLocalLogs() -> Bool {
        let clearedAt = Date()
        diagnostics.clearFilteringCounts(startedAt: clearedAt)
        diagnostics.clearDomainHistory(clearedAt: clearedAt)
        // The "All" clear must erase the SQLite depth store too, exactly like the
        // domain-history-only clear — otherwise Domain History repopulates from
        // dns-events.sqlite as soon as the list reloads (PR #327 review).
        clearDNSEventLogHistory(at: clearedAt)
        hub.clearNetworkActivityLog(notifyTunnel: false)
        hub.clearLavaGuardProgress()
        clearIncidentLedger()
        clearDeviceDebugLog()
        clearSelfReconnectGapMarkers()

        do {
            try writeDiagnosticsClearControl(clearDomainHistory: true, clearFilteringCounts: true, at: clearedAt)
            try persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            // Strong local: see clearDomainHistory.
            let hub = self.hub
            Task {
                await hub.sendTunnelMessage(LavaSecAppGroup.clearDiagnosticsMessage)
                await hub.sendTunnelMessage(LavaSecAppGroup.clearFilteringCountsMessage)
                await hub.sendTunnelMessage(LavaSecAppGroup.clearNetworkActivityLogMessage)
                // The tunnel drains its deferred incident writes then clears, so a queued
                // recordIncident can't resurrect the ledger the app just wiped (CON-1).
                await hub.sendTunnelMessage(LavaSecAppGroup.clearIncidentLedgerMessage)
            }
            ProtectionHapticFeedback.play(.actionSucceeded)
            return true
        } catch {
            hub.presentVPNMessage(
                "Could not clear local logs: %@".lavaLocalizedFormat(error.localizedDescription),
                isError: true
            )
            ProtectionHapticFeedback.play(.actionFailed)
            return false
        }
    }

    /// Erase Domain History from the SQLite depth store for a user clear. Two steps, because
    /// the read floor alone isn't enough (PR #327 review):
    /// 1. Advance the shared "cleared at" floor so the read path (`domainHistoryEvents`) hides
    ///    pre-clear rows immediately — no cross-process write for the common case.
    /// 2. Physically prune those rows NOW via a transient read-write handle, so they leave the
    ///    phone even when the tunnel is stopped and its periodic prune won't run (the offline
    ///    clear path). Appends stay tunnel-only; this is the one app-side write, on an explicit
    ///    user clear. WAL + busy_timeout serialize it against the tunnel's writer when running;
    ///    the file is only opened when it already exists, so we never create an empty DB here.
    /// Every clear path that erases Domain History must call this, or cleared rows resurface
    /// from dns-events.sqlite on reload.
    private func clearDNSEventLogHistory(at clearedAt: Date) {
        LavaSecAppGroup.sharedDefaults.set(
            Int(clearedAt.timeIntervalSince1970 * 1000),
            forKey: LavaSecAppGroup.dnsEventLogClearedAtKey
        )
        guard let dnsEventLogURL,
              FileManager.default.fileExists(atPath: dnsEventLogURL.path),
              let writer = try? DNSEventLog(url: dnsEventLogURL) else {
            return
        }
        try? writer.prune(before: clearedAt)
    }

    func setKeepFilteringCounts(_ keepFilteringCounts: Bool, clearCounts: Bool = true) {
        do {
            try hub.persistKeepFilteringCountsFlag(keepFilteringCounts)
            // Strong local: see clearDomainHistory.
            let hub = self.hub
            Task {
                await hub.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            hub.presentVPNMessage(error.localizedDescription, isError: true)
        }

        if !keepFilteringCounts && clearCounts {
            clearLocalFilteringCounts()
        }
    }

    func setKeepDomainDiagnostics(_ keepDomainDiagnostics: Bool, clearHistory: Bool = true) {
        do {
            try hub.persistKeepDomainDiagnosticsFlag(keepDomainDiagnostics)
            // Strong local: see clearDomainHistory.
            let hub = self.hub
            Task {
                await hub.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            hub.presentVPNMessage(error.localizedDescription, isError: true)
        }

        if !keepDomainDiagnostics && clearHistory {
            clearDomainHistory()
        }
    }

    func refreshDiagnostics() {
        // The incident ledger ages on the same local-log lifecycle as the diagnostics
        // store's fine-grained prune below (the tunnel's startup sweep never runs while
        // the VPN is disabled). Two-phase corroborated — cannot delete off one reading.
        sweepIncidentLedgerRetention()
        guard let diagnosticsURL else {
            diagnosticsReadGate.reset()
            return
        }

        let shouldForceHistoryClear = !hub.keepsDomainDiagnostics && !diagnostics.recentEvents.isEmpty
        let shouldForceCountsClear = !hub.keepsFilteringCounts && diagnostics.hasFilteringCountData
        let shouldForceLocalLogClear = shouldForceHistoryClear || shouldForceCountsClear
        guard let modifiedAt = modificationDate(for: diagnosticsURL) else {
            diagnosticsReadGate.reset()
            if shouldForceHistoryClear {
                clearDomainHistory()
            }
            if shouldForceCountsClear {
                clearLocalFilteringCounts()
            }
            return
        }

        // While the tunnel is connected it OWNS the diagnostics file: it prunes on
        // every debounced write and on its stop-flush, and those writes are NOT
        // cross-process locked. The app therefore must not write a pruned copy back
        // over the tunnel's live writes — a prune write-back landing between the
        // tunnel's final stop-flush load and save would permanently lose the last
        // few Domain History events (UX-4 / PST-3). It's safe to defer: the app
        // still prunes IN MEMORY for display, and persists its prune once it owns the
        // file (i.e. when protection is off, the only writer). No permanent on-disk
        // staleness results, since the tunnel keeps the file pruned while connected.
        //
        // Ownership spans the whole NON-stopped lifecycle, NOT just .connected (Codex #218-class
        // review): the finding's only PERMANENT lost-update is the tunnel's final stop-flush
        // (cleanUpTunnelRuntimeAfterStop → persistDiagnosticsIfNeeded(force:true)) which runs while
        // vpnStatus is .disconnecting. Guarding only .connected would close the transient
        // steady-state clobber (the tunnel re-adds those from its in-memory store) and leave the
        // harmful teardown one open. hub.isProtectionStopPending (the hub's
        // isProtectionStopPendingStatus over the live vpnStatus) is true for .connected /
        // .connecting / .reasserting / .disconnecting and false for .disconnected / .invalid, so
        // the app defers while the tunnel may still write and catches up as sole writer once stopped.
        let tunnelOwnsDiagnosticsFile = hub.isProtectionStopPending

        guard diagnosticsReadGate.shouldRead(modifiedAt: modifiedAt, force: shouldForceLocalLogClear) else {
            // File UNCHANGED since our last read, so the in-memory `diagnostics` still
            // matches disk except for prunes we applied in memory but couldn't persist
            // while the tunnel owned the file. Two reasons to write now, both safe only
            // because in-memory == disk here (no tunnel writes to clobber):
            //   1. A deferred prune from an earlier refresh (`diagnosticsPrunePersistDeferred`)
            //      whose flag we carried until we regained ownership (Codex #225).
            //   2. A fresh expiry: the clock may have crossed the 7-day window while the
            //      app sat idle with no new DNS writes, so Top Domains/exports never show
            //      stale detail.
            // Persist only when the app owns the file (see `tunnelOwnsDiagnosticsFile`);
            // otherwise remember the pending prune for a later refresh. We must NOT flush
            // ahead of the read gate: if the tunnel had written the file, this stale
            // in-memory copy would overwrite its final Domain History events (Codex P1 #225).
            let prunedNow = diagnostics.pruneExpiredFineGrainedData()
            if !tunnelOwnsDiagnosticsFile, diagnosticsPrunePersistDeferred || prunedNow {
                try? persistDiagnostics()
                diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
                diagnosticsPrunePersistDeferred = false
            } else if prunedNow {
                // Pruned in memory but the tunnel owns the file — persist on a later refresh.
                diagnosticsPrunePersistDeferred = true
            }
            return
        }

        // File CHANGED (the tunnel wrote to it): the on-disk store is authoritative and
        // supersedes any prune we deferred against the previous in-memory copy. Drop the
        // flag; the fresh load below re-prunes expired rows and persists them once we own
        // the file, so nothing lingers and no stale write-back can lose the tunnel's data.
        diagnosticsPrunePersistDeferred = false

        var store = DiagnosticsPersistence.load(from: diagnosticsURL)
        store.pruneExpiredFineGrainedData()
        diagnosticsReadGate.markRead(modifiedAt: modifiedAt)
        // Persist when any fine-grained prune removed events — including one
        // `load` already performed in its day-rollover reset — so aged-out domain
        // history does not linger in the file past the 7-day window. Skip the
        // prune-only write-back while the tunnel owns the file (the config-driven
        // clears below still persist — they are coordinated with the tunnel via the
        // diagnostics-control file + IPC, not an unsynchronized prune). The pending
        // flag is always consumed (transient bookkeeping on this local store copy),
        // then gated on ownership so it never drives a write while connected.
        let prunePending = store.consumePendingFineGrainedPrunePersist()
        var shouldPersistClearedLogs = prunePending && !tunnelOwnsDiagnosticsFile

        if !hub.keepsFilteringCounts, store.hasFilteringCountData {
            store.clearFilteringCounts()
            shouldPersistClearedLogs = true
        }

        if !hub.keepsDomainDiagnostics {
            shouldPersistClearedLogs = shouldPersistClearedLogs
                || !store.recentEvents.isEmpty
                || !diagnostics.recentEvents.isEmpty
            store.clearDomainHistory()
        }

        diagnostics = store
        hub.refreshLavaGuardProgressFromDiagnostics()
        if shouldPersistClearedLogs {
            try? persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            diagnosticsPrunePersistDeferred = false
        } else if prunePending {
            // A prune couldn't be persisted because the tunnel owns the file — remember it so the
            // top-of-function flush writes it once the app owns the file again (Codex #225). The
            // pruned `store` is now live in `diagnostics`, so that flush persists the pruned view.
            diagnosticsPrunePersistDeferred = true
        }
    }

    // MARK: - Bug reports & rage shake

    func prepareBugReport(context: BugReportContext) {
        hub.refreshReports()
        let inputs = PreparedBugReportInputs(
            snapshot: hub.currentFilterSnapshot(),
            debugLogEntries: loadBugReportDebugLogEntries(),
            selfReconnectTimes: loadSelfReconnectAttemptTimes()
        )
        preparedBugReportInputs = inputs
        bugReportDraft = makeBugReportBundle(context: context, inputs: inputs)
        bugReportSendState = .idle
    }

    /// Cheap per-keystroke draft refresh: re-wrap the user-entered `context`
    /// around the environment snapshot captured by the last `prepareBugReport`,
    /// instead of re-reading the diagnostics/health/debug-log files and
    /// rebuilding the full blocklist union on every keystroke (UR-5: Feedback
    /// typing lag). Only the affected-site decision is recomputed, and that is a
    /// lookup against the already-built snapshot. Falls back to a full prepare
    /// when no snapshot has been captured yet.
    func refreshBugReportDraftContext(context: BugReportContext) {
        guard let inputs = preparedBugReportInputs else {
            prepareBugReport(context: context)
            return
        }

        bugReportDraft = makeBugReportBundle(context: context, inputs: inputs)
        bugReportSendState = .idle
    }

    func sendBugReport(context: BugReportContext) async {
        let bundle = BugReportSubmissionBundlePolicy.bundleToSubmit(
            draft: bugReportDraft,
            currentContext: context
        ) { [self] in
            makeBugReportBundle(context: context)
        }
        bugReportDraft = bundle
        bugReportSendState = .sending

        do {
            let reportID = try await submitBugReport(bundle)
            bugReportSendState = .sent(reportID: reportID)
        } catch {
            bugReportSendState = .failed(message: error.localizedDescription)
        }
    }

    func resetBugReportSendState() {
        bugReportSendState = .idle
    }

    /// The heavy, user-input-independent inputs to a bug-report bundle: the
    /// compiled filter snapshot (the full blocklist union) and the parsed
    /// lifecycle debug-log entries. Captured once per `prepareBugReport` so the
    /// per-keystroke draft refresh can reuse them (UR-5).
    private struct PreparedBugReportInputs {
        let snapshot: FilterSnapshot
        let debugLogEntries: [BugReportDebugLogEntry]
        let selfReconnectTimes: [Date]
    }

    private var preparedBugReportInputs: PreparedBugReportInputs?

    private func makeBugReportBundle(context: BugReportContext) -> BugReportBundle {
        makeBugReportBundle(
            context: context,
            inputs: PreparedBugReportInputs(
                snapshot: hub.currentFilterSnapshot(),
                debugLogEntries: loadBugReportDebugLogEntries(),
                selfReconnectTimes: loadSelfReconnectAttemptTimes()
            )
        )
    }

    // The wide-hub-state ASSEMBLY stays a hub bridge method (Phase D4 bridge-width
    // judgement — see DiagnosticsHubBridging's doc): this seam passes in the pieces the
    // controller owns. The live local-observability reads (`diagnostics`, the gap
    // markers, the incident ledger) are evaluated here per-make — same per-keystroke
    // read behavior as the pre-peel assembly, which read them inline while building
    // the bundle (only the position within the build moved; nothing else touches
    // those stores in between).
    private func makeBugReportBundle(
        context: BugReportContext,
        inputs: PreparedBugReportInputs
    ) -> BugReportBundle {
        hub.makeBugReportBundle(
            context: context,
            inputs: BugReportBundleInputs(
                snapshot: inputs.snapshot,
                debugLogEntries: inputs.debugLogEntries,
                selfReconnectTimes: inputs.selfReconnectTimes,
                diagnostics: diagnostics,
                selfReconnectGap: loadSelfReconnectGapRecord(),
                recentIncidents: loadRecentIncidentLedgerRecords()
            )
        )
    }

    /// Read-only snapshot of the tunnel's persisted self-reconnect attempt timeline (shared
    /// app-group defaults). Surfaced in the bug report's incident summary (LAV-94 B); never
    /// written here — the tunnel owns the key, the app only reads it.
    private func loadSelfReconnectAttemptTimes() -> [Date] {
        let raw = LavaSecAppGroup.sharedDefaults.array(
            forKey: LavaSecAppGroup.selfReconnectAttemptTimesDefaultsKey
        ) as? [Double] ?? []
        return raw.map(Date.init(timeIntervalSince1970:))
    }

    /// Report view of the tunnel's incident ledger (OBS R2): the timeline that survives
    /// the policy stores' by-design forgetting. The READ is a pure view — `recentRecords`
    /// filters to the 7-day report window and never writes back, so a skewed clock at
    /// report time cannot wipe evidence (COH-4). On-disk retention is the SEPARATE
    /// corroborated sweep below, run first: a report can be the first ledger touch in
    /// days when the VPN is off.
    private func loadRecentIncidentLedgerRecords() -> [IncidentLedgerRecord] {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return []
        }
        sweepIncidentLedgerRetention()
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        return IncidentLedgerPersistence.load(from: ledgerURL).recentRecords()
    }

    /// App-side lifecycle hook for the ledger's two-phase retention sweep (arm → 24 h
    /// corroborated confirm — see `IncidentLedger.sweepExpired`): with the VPN disabled
    /// or simply never relaunched, tunnel starts stop happening, so the app must also
    /// age the file or expired rows outlive the Local Logs 7-day promise on disk.
    /// Skew-safe by construction — a single (possibly lying) clock reading can at most
    /// ARM, never delete — so unlike the report read, running this anywhere is harmless.
    private func sweepIncidentLedgerRetention() {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return
        }
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        IncidentLedgerPersistence.sweepExpired(at: ledgerURL)
    }

    /// Clear-all-logs privacy contract: the ledger is a local log like the others, so the
    /// user's clear wipes it too. The app's OWN removal here is the reliable one — blocking,
    /// off the tunnel's DNS/teardown path. Because the tunnel also defers incident writes
    /// onto its serial IO queue (CON-1), a queued pre-clear write could recreate the file, so
    /// `clearAllLocalLogs` ALSO sends `clearIncidentLedgerMessage` — the tunnel drains that
    /// queue, then best-effort `tryClear`s (non-blocking, so it can never stall the
    /// self-reconnect teardown — Codex #200 P2). If that rare drop leaves a drained pre-clear
    /// record behind, the corroborated retention sweep ages it out.
    private func clearIncidentLedger() {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return
        }
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        IncidentLedgerPersistence.clear(at: ledgerURL)
    }

    /// PST-6: the device debug log (`vpn-debug-log.jsonl` + its rotated `.1` generation) is
    /// the store that carries the resolver endpoints (incl. custom DNS) and the network-change
    /// timeline a post-clear export would otherwise still ship. Clear-all now wipes it too.
    /// Both the app and the tunnel append via a single `O_APPEND` `write(2)` with no in-memory
    /// buffer, so removing the files is race-safe: a concurrent or subsequent tunnel append
    /// just `O_CREAT`s a fresh, post-clear file — no pre-clear line can be resurrected.
    private func clearDeviceDebugLog() {
        LavaSecDeviceDebugLog.reset()
    }

    /// PST-6: the LAV-92/93 self-reconnect gap markers (started / ended / count) are durable
    /// observability written by the tunnel. They are observability-ONLY — the recovery/cap
    /// policy never reads them — so the app clears them directly (last-writer-wins app-group
    /// defaults, no deferred queue); the tunnel writes fresh markers on the next gap, and a
    /// stray `ended` with no `started` is ignored by `loadSelfReconnectGapRecord`. Deliberately
    /// NOT cleared: `selfReconnectAttemptTimes` (the cap/cooldown policy READS it — wiping it
    /// would perturb the founder-frozen recovery control flow) and the tunnel-health snapshot
    /// (operational fail-closed state, not carried in the local export, same frozen-control-flow
    /// reason). Those hold no resolver endpoints or domains, so they are not a privacy leak.
    private func clearSelfReconnectGapMarkers() {
        let defaults = LavaSecAppGroup.sharedDefaults
        defaults.removeObject(forKey: LavaSecAppGroup.selfReconnectGapStartedAtDefaultsKey)
        defaults.removeObject(forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKey)
        defaults.removeObject(forKey: LavaSecAppGroup.selfReconnectGapCountDefaultsKey)
    }

    /// Read-only view of the tunnel's durable self-reconnect gap markers (LAV-92/93): the
    /// rate-limiter's attempt store forgets by design (productive credit + 600 s prune), so
    /// these keys are the only record that survives to a late-filed report. Written by the
    /// tunnel only; the app just reads.
    private func loadSelfReconnectGapRecord() -> SelfReconnectGapRecord? {
        let defaults = LavaSecAppGroup.sharedDefaults
        let startedAtRaw = defaults.double(forKey: LavaSecAppGroup.selfReconnectGapStartedAtDefaultsKey)
        guard startedAtRaw > 0 else {
            return nil
        }
        let endedAtRaw = defaults.double(forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKey)
        return SelfReconnectGapRecord(
            startedAt: Date(timeIntervalSince1970: startedAtRaw),
            // Accept an end only if it is AFTER the start read alongside it: the tunnel's
            // open/close are separate cross-process defaults writes, so a racy read (or an
            // extension killed mid-open) can pair a new start with the PREVIOUS gap's end —
            // a bogus "closed" gap that would mask a still-open outage. Stale end = open.
            endedAt: endedAtRaw > startedAtRaw ? Date(timeIntervalSince1970: endedAtRaw) : nil,
            cumulativeCount: defaults.integer(forKey: LavaSecAppGroup.selfReconnectGapCountDefaultsKey)
        )
    }

    private func submitBugReport(_ bundle: BugReportBundle) async throws -> String {
        let body = bundle.makeRequestBody()
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // Best-effort App Attest: prove this is a genuine build on real hardware.
        // nil on unsupported devices/simulators or any failure — the server is
        // fail-open during rollout, so we simply submit without the headers then.
        // Bind the attestation to SHA256(this exact body) so a captured attestation can't be
        // replayed against a different report; the server recomputes the same clientDataHash.
        let bodyHash = Data(SHA256.hash(data: data))
        let attestation = await Self.acquireAppAttestation(bodyHash: bodyHash)
        var lastError: Error?

        for endpoint in Self.bugReportEndpointURLs {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                attestation?.apply(to: &request)
                request.httpBody = data

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BugReportSubmissionError(message: "The server returned an invalid response.")
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    // A 429 is terminal — surface it now instead of retrying the
                    // fallback (see BugReportRateLimitedError).
                    if httpResponse.statusCode == 429 {
                        throw BugReportRateLimitedError()
                    }
                    let serverMessage = String(data: responseData, encoding: .utf8) ?? "No response body"
                    throw BugReportSubmissionError(
                        message: "The server returned HTTP \(httpResponse.statusCode): \(serverMessage)"
                    )
                }

                let decoded = try JSONDecoder().decode(BugReportSubmitResponse.self, from: responseData)
                return decoded.reportID
            } catch is BugReportRateLimitedError {
                // Give a rate-limited caller a friendly, actionable message and stop —
                // do not fail over to the fallback endpoint.
                throw BugReportSubmissionError(
                    message: "Please wait a moment and try again."
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? BugReportSubmissionError(message: "Could not send the bug report.")
    }

    // Fetch a one-time challenge from the API and produce an Apple App Attest
    // attestation over it. Returns nil (submit proceeds unattested) when App
    // Attest is unsupported, no challenge could be fetched, or attestation fails.
    private static func acquireAppAttestation(bodyHash: Data) async -> AppAttestHeaders? {
        guard AppAttestClient.isSupported else {
            return nil
        }
        guard let challenge = await fetchAppAttestChallenge() else {
            return nil
        }
        return await AppAttestClient.attest(challenge: challenge, bodyHash: bodyHash)
    }

    // Cap each challenge fetch so a slow or blackholed /v1/attest-challenge cannot
    // hold the feedback sheet in "Submitting". Attestation is best-effort, so a
    // timeout just falls through to the next endpoint and ultimately to nil (submit
    // proceeds unattested) rather than waiting out URLSession's default ~60s.
    private static let appAttestChallengeTimeout: TimeInterval = 3

    // The App Attest challenge is a globally-shared, stateless HMAC token: the SAME worker
    // (same signing secret) sits behind both the production and workers.dev-fallback base
    // URLs, so a challenge issued by either host verifies at either submit endpoint. That lets
    // us race both hosts concurrently and take production's result (or the fallback's if
    // production yields nil) — capping the worst-case wait at one timeout (~3s) instead of two
    // sequential ones when a host is slow or blackholed.
    private static func fetchAppAttestChallenge() async -> String? {
        async let production = fetchAppAttestChallenge(from: LavaSecAPI.productionBaseURL)
        async let fallback = fetchAppAttestChallenge(from: LavaSecAPI.fallbackBaseURL)
        if let challenge = await production {
            return challenge
        }
        return await fallback
    }

    private static func fetchAppAttestChallenge(from base: URL) async -> String? {
        let url = base
            .appendingPathComponent("v1")
            .appendingPathComponent("attest-challenge")
        var request = URLRequest(url: url)
        request.timeoutInterval = appAttestChallengeTimeout
        // Best-effort and intentionally silent on failure: attestation is fail-open (a nil
        // challenge just submits the report unattested, never blocking the user), and the
        // server already records the outcome (`app_attest_ok` / `app_attest_soft_fail`), so a
        // client-side log of the fetch failure would be redundant.
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            if let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let challenge = object["challenge"] as? String, !challenge.isEmpty {
                return challenge
            }
            return nil
        } catch {
            return nil
        }
    }

    private func loadBugReportDebugLogEntries() -> [BugReportDebugLogEntry] {
        BugReportDebugLogEntry.parseJSONLines(concatenating: deviceDebugLogGenerations())
    }

    private static var bugReportEndpointURLs: [URL] {
        [LavaSecAPI.productionBaseURL, LavaSecAPI.fallbackBaseURL].map {
            $0
                .appendingPathComponent("v1")
                .appendingPathComponent("bug-reports")
        }
    }

    // MARK: - Device debug-log reads & diagnostics persistence plumbing

    // The local export carries far more debug-log history than the Feedback
    // report (which caps at 40 to bound its upload payload): the export is a
    // local, user-controlled diagnostic file, so a deep trace is the point.
    // Same redaction (BugReportDebugLogEntry keeps only allowlisted detail keys).
    // Internal (not private): the hub's makeLocalLogExportArchive — the export
    // assembly that stayed hub-side — calls it for the debug-log slice this
    // controller owns.
    func loadDeviceDebugLogEntriesForExport() -> [BugReportDebugLogEntry] {
        BugReportDebugLogEntry.parseJSONLines(
            concatenating: deviceDebugLogGenerations(),
            limit: 5_000
        )
    }

    // The 8 MB rotation boundary can land between an incident and the report/export
    // (LavaSecDeviceDebugLog.rotate keeps one previous generation for exactly this case);
    // reading only the current file makes a just-rotated log look near-empty. Rotated
    // generation first: the entry cap keeps the newest lines via suffix, and both callers
    // bound the result by entry count, so the extra generation costs parse time only.
    //
    // A rotation can also land BETWEEN the two reads (the tunnel's appendLine moves
    // current -> .1 at the size cap): reading .1 first and current second would then return
    // the old rotated generation plus the brand-new current file, dropping the generation
    // that held the incident window. rotate() replaces the .1 inode, and a rename preserves
    // the moved file's own mtime — so the .1 file identity (inode) is the rotation signal:
    // re-read when it changed mid-read, and after repeated churn fall back to the last
    // (possibly gapped) read, which is still no worse than the pre-rotation-aware loader.
    private func deviceDebugLogGenerations() -> [Data] {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return []
        }
        let generationURLs = [
            containerURL.appendingPathComponent(LavaSecAppGroup.vpnDebugLogRotatedFilename),
            containerURL.appendingPathComponent(LavaSecAppGroup.vpnDebugLogFilename),
        ]
        var generations: [Data] = []
        for _ in 0..<3 {
            let identityBefore = fileIdentity(at: generationURLs[0])
            generations = generationURLs.compactMap { try? Data(contentsOf: $0) }
            if fileIdentity(at: generationURLs[0]) == identityBefore {
                break
            }
        }
        return generations
    }

    private func fileIdentity(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func persistDiagnostics() throws {
        guard let diagnosticsURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        try DiagnosticsPersistence.save(diagnostics, to: diagnosticsURL)
    }

    private func writeDiagnosticsClearControl(
        clearDomainHistory: Bool = false,
        clearFilteringCounts: Bool = false,
        at now: Date = Date()
    ) throws {
        guard let diagnosticsControlURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        let existingControl = DiagnosticsControlPersistence.load(from: diagnosticsControlURL)
        // `now` matches the timestamp stamped into the store's applied-marker by the
        // paired clear call, so the tunnel's force-apply gate dedups exactly (PST-1).
        try DiagnosticsControlPersistence.save(
            DiagnosticsControl(
                clearDomainHistoryRequestedAt: clearDomainHistory ? now : existingControl.clearDomainHistoryRequestedAt,
                clearFilteringCountsRequestedAt: clearFilteringCounts ? now : existingControl.clearFilteringCountsRequestedAt
            ),
            to: diagnosticsControlURL
        )
    }

    private var diagnosticsURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsFilename)
    }

    private var diagnosticsControlURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsControlFilename)
    }

    private var dnsEventLogURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.dnsEventLogFilename)
    }

    /// Read-only handle on the tunnel-written Domain History depth store. Opened lazily and
    /// retried until the file exists (a fresh install before the tunnel's first run).
    private var dnsEventLogReader: DNSEventLog?

    private func domainHistoryLog() -> DNSEventLog? {
        if let dnsEventLogReader {
            return dnsEventLogReader
        }
        guard let dnsEventLogURL,
              FileManager.default.fileExists(atPath: dnsEventLogURL.path) else {
            return nil
        }
        dnsEventLogReader = try? DNSEventLog(url: dnsEventLogURL, readOnly: true)
        return dnsEventLogReader
    }

    /// Domain History rows for the list, drawn from the SQLite depth store (the full 7-day
    /// window) instead of the 250-entry JSON buffer. Honors a local "Clear Domain History" via
    /// the shared-defaults floor. Returns `[]` when the store isn't available yet (the list
    /// then simply shows its empty state until the tunnel has written the first events).
    func domainHistoryEvents(action: FilterAction, searchText: String, limit: Int) -> [DNSQueryEvent] {
        guard let log = domainHistoryLog() else {
            // Before the tunnel has run once on this build, dns-events.sqlite doesn't exist yet
            // (or failed to open), but diagnostics.json can still hold the pre-existing last-250
            // events this view used to show. Fall back to them so an upgraded install isn't
            // blank until protection starts and seeds the DB (PR #327 review). The JSON buffer
            // is cleared by clearDomainHistory, so this path honors clears too.
            return diagnostics.recentEvents(action: action, searchText: searchText, limit: limit)
        }
        // Floor the read at BOTH the user-clear timestamp AND the 7-day fine-grained retention
        // cutoff. The retention floor matters when the tunnel has been stopped >7 days: its
        // physical prune hasn't run, so stale rows are still on disk — filtering here keeps
        // Domain History honoring the "kept on this iPhone for 7 days" promise regardless of
        // tunnel state (the tunnel + app-clear paths handle the physical delete). PR #327 review.
        let clearFloorMs = LavaSecAppGroup.sharedDefaults.integer(forKey: LavaSecAppGroup.dnsEventLogClearedAtKey)
        let retentionFloorMs = Int((Date().timeIntervalSince1970 - LocalLogRetention.fineGrainedWindow) * 1000)
        let floorMs = max(clearFloorMs, retentionFloorMs)
        let since: Int64? = floorMs > 0 ? Int64(floorMs) : nil
        return log.page(action: action, searchText: searchText, since: since, limit: limit)
            .map { entry in
                DNSQueryEvent(
                    id: Self.stableEventID(forRowID: entry.id),
                    timestamp: entry.timestamp,
                    domain: entry.domain,
                    decision: entry.decision
                )
            }
    }

    /// Deterministic UUID from the sqlite rowid so SwiftUI list identity is stable across
    /// reloads — a fresh `UUID()` per read would thrash the diff (reset scroll and animations).
    private static func stableEventID(forRowID rowID: Int64) -> UUID {
        let bytes = withUnsafeBytes(of: UInt64(bitPattern: rowID).bigEndian) { Array($0) }
        return UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]
        ))
    }

    // Same helper the hub keeps for ITS read gates (tunnel health, network activity) —
    // duplicated rather than bridged because it is a pure disk stat with no hub state.
    private func modificationDate(for url: URL?) -> Date? {
        // Fetch only the content-modification date rather than building
        // `FileManager.attributesOfItem`'s full attribute dictionary (owner,
        // permissions, size, type, every timestamp…). Same `st_mtime` semantics,
        // less work per stat — these report-refresh paths poll several files.
        // NB: a cross-refresh cache is intentionally avoided — this date is the
        // signal used to detect the tunnel process's writes, so a TTL would mask
        // fresh data and a vnode monitor is unreliable for atomic-rename writes.
        guard let url else {
            return nil
        }

        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
