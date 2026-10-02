import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - Tunnel health & messaging

    /// Upgrades an already-running legacy profile through the normal fenced restart.
    /// Attempt once per app launch; a failed attempt remains visible and an explicit restart retries.
    func reconcileDNSRouteEnforcementIfNeeded() async {
        guard !isHeadless, hasCompletedOnboarding, userProtectionIntent.isEnabled,
              !didAttemptDNSRouteEnforcementMigration,
              vpnStatus == .connected,
              let provider = tunnelManager?.protocolConfiguration as? NETunnelProviderProtocol,
              !provider.includeAllNetworks,
              !provider.enforceRoutes || provider.excludeLocalNetworks,
              shouldEnforceDNSRoutes,
              let containerURL = LavaSecAppGroup.containerURL,
              let generation = try? LavaProtectionCommandService.captureExternalRestartGeneration(),
              protectionActionOrchestrator.claim(.reconnect) else { return }
        didAttemptDNSRouteEnforcementMigration = true
        let intentRevision = userProtectionIntent.revision
        defer { protectionActionOrchestrator.release(.reconnect) }
        logVPNDebugEvent("dns-route-enforcement-migration-requested")
        await reconnectProtectionNow(
            playsOutcomeHaptic: false,
            continueIfCurrent: { [weak self] in
                guard let self, !Task.isCancelled,
                      self.userProtectionIntent.isEnabled,
                      self.userProtectionIntent.revision == intentRevision,
                      (try? LavaProtectionCommandService.captureExternalRestartGeneration()) == generation
                else { return false }
                return ProtectionRestoreIntentStore.read(containerURL: containerURL)
                    .resolvedIntent(fallingBackTo: self.userProtectionIntent.isEnabled)
            },
            requiresActiveSession: true)
    }

    func notifyTunnelSnapshotUpdated(operationID: LatencyOperationID? = nil) async {
        await sendTunnelMessage(
            LavaSecAppGroup.reloadSnapshotMessage,
            fallbackMessage: "Updated filter. Restart protection if the VPN does not pick it up.",
            operationID: operationID
        )
    }

    func notifyTunnelProtectionPauseUpdated(operationID: LatencyOperationID? = nil) async {
        await sendTunnelMessage(
            LavaSecAppGroup.reloadProtectionPauseMessage,
            fallbackMessage: "Updated protection pause. Restart protection if the VPN does not pick it up.",
            operationID: operationID
        )
    }

    func makeProtectionRestoreRequest() -> ProtectionRestoreRequest {
        userProtectionIntent.makeRestoreRequest(
            externalRestartGeneration: LavaProtectionCommandService.currentExternalRestartGeneration()
        )
    }

    func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async {
        #if targetEnvironment(simulator)
        return
        #else
        // Never restore/enable protection while onboarding is incomplete. The
        // launch catalog sync (syncCatalogIfStale -> performCatalogSync) calls this. A reinstall
        // can still load an enabled intent from shared state or observe an iOS-retained on-demand
        // manager, so without this gate a pre-onboarding restore could reach enableProtection
        // (-> saveToPreferences -> VPN permission prompt) before the user reaches the VPN step.
        // neutralizeInheritedProtectionDuringOnboarding removes the inherited
        // config; this closes the catalog-/filter-restore path too.
        guard hasCompletedOnboarding else {
            return
        }

        // A standing chained refusal no longer blocks automatic restore. The provider starts the
        // latched DNS-only path under any refusal, so restoring re-arms filtering instead of
        // re-arming a crash loop; the latch's own breaker holds a crash-looping device in
        // DNS-only. Only an explicit user action turns protection off
        // (plans/2026-09-18-fail-closed-protection-startup-failures-plan.md).
        // pinned: ProtectionOnDemandSourceTests.testAutomaticRestoreIsNotBlockedByAStandingChainedRefusal

        guard request.wasEnabled, request.intendedEnabled else {
            return
        }

        // Refresh first without occupying the action claim, then revalidate the LIVE explicit intent
        // and claim `.turnOn` synchronously on the main actor. `request.wasEnabled` is only the caller's
        // pre-await reason to consider a restore; a user turn-off can complete while the refresh is
        // suspended, and that newer intent must win. The orchestrator helper leaves no await between
        // this predicate and the claim, so a concurrent user action cannot slip through the seam.
        var automaticRestoreLease: ProtectionLifecycleLease?
        await protectionActionOrchestrator.runAutomaticRestoreAfterRefresh(
            refresh: { await self.refreshProtectionStatus(force: true) },
            shouldRestore: {
                self.hasCompletedOnboarding
                    && self.userProtectionIntent.allows(request)
                    && !self.isProtectionEnabledStatus(self.vpnStatus)
                    && !self.isAwaitingOnDemandReconnect
            },
            claimExternalExclusion: {
                automaticRestoreLease = LavaProtectionCommandService.claimAutomaticRestoreLease(
                    expectedExternalRestartGeneration: request.externalRestartGeneration
                )
                return automaticRestoreLease != nil
            },
            validateExternalExclusion: {
                guard let automaticRestoreLease else {
                    return false
                }
                return LavaProtectionCommandService.renewProtectionLifecycleLease(
                    automaticRestoreLease
                )
            },
            releaseExternalExclusion: {
                if let automaticRestoreLease {
                    await LavaProtectionCommandService.releaseProtectionLifecycleLease(automaticRestoreLease)
                }
            }
        ) { validateOwnership in
            guard let automaticRestoreLease else {
                return false
            }
            let leaseRenewal = LavaProtectionCommandService.startProtectionLifecycleLeaseRenewal(
                automaticRestoreLease
            )
            defer {
                leaseRenewal.cancel()
            }
            return await self.enableProtection(
                logUserAction: false,
                playsOutcomeHaptic: false,
                persistsExplicitIntent: false,
                continueIfLifecycleLeaseOwned: validateOwnership
            )
        }
        #endif
    }

    // Connect-On-Demand can bring the tunnel up on launch (or after iOS tears it
    // down on a network change) before the app has pushed a snapshot. A cold
    // tunnel with no reusable persisted snapshot loads FAIL-CLOSED — it blocks
    // all traffic — and never recovers on its own: restoreProtectionIfNeeded
    // early-returns once the tunnel already reads as "connected", and a non-stale
    // launch never re-syncs or re-pushes. So whenever protection is active at
    // launch, re-establish and push the snapshot so the tunnel reloads its real
    // rules out of fail-closed. Fail-closed stays the safe default; this just
    // supersedes it promptly. (Fixes: filters shown red / traffic blocked after
    // an app restart while Connect-On-Demand keeps the tunnel up.)
    //
    // ALSO covers the armed-but-DROPPED launch (`.disconnected` + on-demand armed):
    // restoreProtectionIfNeeded deliberately skips enableProtection there (letting iOS
    // reconnect), which also skips the snapshot publish enableProtection would have done.
    // Without this the stale/missing `latest.json` pointer stays unrepaired until iOS
    // reconnects, at which point the tunnel starts cold on old/fail-closed rules. Publishing
    // the snapshot here — WITHOUT starting the VPN — hands iOS's on-demand reconnect the real
    // rules (the reconnect UI is unaffected; only the shared snapshot is republished).
    func reconcileTunnelSnapshotAfterLaunch() async {
        #if targetEnvironment(simulator)
        return
        #else
        await refreshProtectionStatus(force: true)
        guard isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect else {
            return
        }

        do {
            let startup = try await preparedSnapshotForProtectionStartup()
            try await persistSharedState(
                preparedSnapshot: startup.preparedSnapshot,
                rewritesRuleArtifacts: !startup.reusedPersistedArtifacts
            )
            await notifyTunnelSnapshotUpdated()
            clearFailClosedReconcileRetryLadder()
            #if DEBUG
            logVPNDebugEvent("launch-snapshot-reconciled", details: [
                "reusedPersistedArtifacts": "\(startup.reusedPersistedArtifacts)",
                "compiledRuleCount": "\(compiledRuleCount)"
            ])
            #endif
        } catch {
            // INV-TIER-1: a tier-limit throw here is the FIRST app-side signal for the
            // lapsed-Plus / grown-union cohort whose tunnel just cold-started fail-closed
            // (startup reuse and LKG both tier-rejected). Swallowing it — as every other
            // reconcile failure is, correctly — leaves the device blocking all DNS with the
            // status still reading like a healthy cache load; surface the actionable tier
            // message on the existing status surface instead.
            if case FilterSnapshotPreparationError.exceedsTierFilterRuleLimit = error {
                surfaceTierBudgetStatusMessage()
            } else {
                // EVERY failure here has the consequence the tier-budget comment describes,
                // not just the tier-budget case (INV-TIER-1 — the filter rule limit, nothing to
                // do with the DNS tiers of `docs/architecture/dns-tiers.md`). If this reconcile
                // fails while the tunnel cold-started fail-closed, the device blocks all DNS and
                // the UI still reads healthy — and the repair does not retry, because this runs
                // once per process. The tier-budget case was singled out only because it was the
                // first one anyone hit.
                //
                // Observed on device (S9): a total DNS outage that never self-healed, whose
                // only trace was a QA-only log line, and whose error text
                // ("Custom blocklist URLs must use a public host") named the user's
                // configuration for what was actually the app's own sinkhole answer.
                surfaceSnapshotReconcileFailureStatusMessage()
                scheduleFailClosedReconcileRetryIfNeeded()
            }
            // UNCONDITIONAL, deliberately. `LavaSecDeviceDebugLog` is compiled in every
            // configuration by design, and this is a total-outage state: gating its only
            // record behind DEBUG/QA means a field device in this state carries no evidence
            // of it at all — not even in a bug report.
            //
            // The payload is DOMAIN AND CODE ONLY. It carried the localized description
            // until this call moved to `errorIdentityDetails`, and the description is
            // exactly what could not stay: `customBlocklistUnavailable` interpolates a
            // source's display name, which falls back to the HOST for an unnamed custom
            // list, and `errorDescription` is allowlisted into the report bundle. Domain
            // and code carry the diagnosis without carrying a hostname the user never
            // agreed to send — see `errorIdentityDetails`'s own note.
            logVPNDebugEvent("launch-snapshot-reconcile-failed", details: errorIdentityDetails(error))
        }
        #endif
    }

    // Mirrors the RootView @AppStorage("hasSeenLavaOnboarding") gate. The VPN
    // restore/reconcile launch chain runs from init regardless of UI state, so it
    // reads this directly to avoid acting on protection before the user has
    // finished onboarding and chosen to enable it.
    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "hasSeenLavaOnboarding")
    }

    // Fundamental guard against the "fresh install shows VPN already on / filters
    // red mid-onboarding" (and the "VPN permission prompt at step 1") class of
    // bug. iOS does not reliably remove a VPN profile when the app is deleted, so
    // a reinstall can land on an *incomplete* onboarding with a pre-existing,
    // orphaned config. If that config has Connect-On-Demand enabled (or a tunnel
    // already up), iOS keeps a cold tunnel alive — it loads fail-closed and blocks
    // traffic before the user has chosen any blocklists.
    //
    // Until onboarding is complete, such inherited *active* protection must be
    // fully removed. Critically, we REMOVE the config (removeFromPreferences)
    // rather than save a modification to it: saveToPreferences (what
    // setManagerOnDemand uses) re-shows the "Add VPN Configurations" system
    // prompt on an orphaned profile this install does not own, firing the dialog
    // at app init before the onboarding sheet even renders. removeFromPreferences
    // is silent and leaves a pristine state; the user installs a fresh profile at
    // the VPN step.
    //
    // No-op on a clean install (no manager) and when the inherited config is
    // already inert (disconnected, no on-demand), so a profile freshly installed
    // at the onboarding VPN step survives a mid-onboarding relaunch (see
    // applyConfiguration / ProtectionOnDemandSourceTests).
    func neutralizeInheritedProtectionDuringOnboarding() async {
        #if targetEnvironment(simulator)
        return
        #else
        do {
            guard let manager = try await loadExistingTunnelManager() else {
                return
            }

            let wasOnDemand = manager.isOnDemandEnabled
            let status = manager.connection.status
            let isUpOrComingUp = status == .connected || status == .connecting || status == .reasserting
            guard wasOnDemand || isUpOrComingUp else {
                return
            }

            manager.connection.stopVPNTunnel()
            try await vpnLifecycleController.removeManager(manager)
            tunnelManager = nil
            updateProtectionStatus(from: nil)
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("onboarding-neutralized-inherited-protection", details: [
                "wasOnDemand": "\(wasOnDemand)",
                "connectionStatus": "\(status.rawValue)"
            ])
            #endif
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("onboarding-neutralize-failed", details: errorDebugDetails(error))
            #endif
        }
        #endif
    }

    func sendTunnelMessage(
        _ message: String,
        fallbackMessage: String = "Updated local settings. Restart protection if the VPN does not pick them up.",
        operationID: LatencyOperationID? = nil
    ) async {
        #if targetEnvironment(simulator)
        return
        #else
        // Runs on the HEADLESS model too: a Focus warm switch must reload the RUNNING tunnel so the new
        // filter takes effect in the background — do NOT guard this whole method on !isHeadless (that would
        // silently defeat the background switch). Only the @Published vpnMessage writes below are guarded,
        // since they would be dead state on the throwaway headless model (review #5).
        if tunnelManager == nil {
            do {
                tunnelManager = try await loadExistingTunnelManager()
            } catch {
                if !isHeadless {
                    vpnMessage = fallbackMessage
                    vpnMessageIsError = false
                }
                return
            }
        }

        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
              isProtectionEnabledStatus(session.status)
        else {
            return
        }

        let operationID = operationID ?? LatencyOperationID.make()
        #if DEBUG || LAVA_QA_TOOLS
        let trace = LatencyTrace(
            operationID: operationID,
            sink: LatencyDebugLogEventSink(operationKind: "providerMessage") { [weak self] event, details in
                self?.logVPNDebugEvent(event, details: details)
            }
        )
        trace.record("provider.message.request", details: ["kind": message])
        let span = trace.beginSpan("provider.message.reply", details: ["kind": message])
        #endif
        let messageData = LavaSecProviderMessageCodec.encode(kind: message, operationID: operationID.rawValue)

        do {
            try session.sendProviderMessage(messageData) { _ in
                #if DEBUG || LAVA_QA_TOOLS
                span.end(details: ["status": "reply"])
                #endif
            }
            #if DEBUG || LAVA_QA_TOOLS
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.providerMessageAckTimeout) {
                span.end(details: ["status": "timeout"])
            }
            #endif
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            var details = errorDebugDetails(error)
            details["status"] = "send-error"
            span.end(details: details)
            #endif
            if !isHeadless {
                vpnMessage = fallbackMessage
                vpnMessageIsError = false
            }
        }
        #endif
    }

    func requestTunnelHealthFlush() async {
        #if targetEnvironment(simulator)
        return
        #else
        if tunnelManager == nil {
            tunnelManager = try? await loadExistingTunnelManager()
        }

        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
              isProtectionEnabledStatus(session.status)
        else {
            return
        }

        // BOUNDED, for the same reason the handshake query is: `sendProviderMessage`'s reply
        // handler is never called if the NE is jetsammed mid-request (`INV-MEM-1`), and this
        // await has a caller that is not a poll — the Feedback submit path. An unbounded wait
        // there would strand the submission permanently, during exactly the tunnel failure the
        // user is trying to report (Codex P2, PR #620). On timeout we proceed with the
        // diagnostics already on disk; a flush is an improvement to the sample, never a
        // precondition for it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = TunnelHealthFlushReplyBox(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.tunnelHealthFlushTimeout) {
                box.resume()
            }
            do {
                try session.sendProviderMessage(Data(LavaSecAppGroup.flushTunnelHealthMessage.utf8)) { _ in
                    box.resume()
                }
            } catch {
                box.resume()
            }
        }
        #endif
    }

    /// A flush is an improvement to the sample, not a precondition for it, so the wait is bounded
    /// and a timeout simply proceeds. Longer than the handshake query's 2 s because this handler
    /// does real work tunnel-side — the locked-boot stamp, the chained mirror, a forced persist
    /// and the suppressed-failure flush — but short enough that a jetsammed NE cannot hold up a
    /// bug report.
    private static let tunnelHealthFlushTimeout: TimeInterval = 3

    /// One-shot resume guard, mirroring `HandshakeReplyBox`: the reply handler, the throw and the
    /// deadline all race, and the first to arrive wins so the continuation resumes exactly once.
    /// `@unchecked Sendable` — the `NSLock` serialises them.
    private final class TunnelHealthFlushReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    /// The handshake query polls unthrottled, so a lost round-trip must not stall the caller: if the
    /// NE is jetsammed mid-request the reply handler never fires (`INV-MEM-1`). This deadline resumes
    /// the query with `nil` ("unknown") so the poll loop stays alive. (Kilo #556)
    private static let chainedHandshakeQueryTimeout: TimeInterval = 2

    enum HandshakeQueryReason: String, Sendable {
        case reply, timeout, invalidReply = "invalid-reply", sendFailed = "send-failed"
        case sessionUnavailable = "session-unavailable"
    }
    struct HandshakeQueryResult: Sendable {
        let reply: LavaSecAppGroup.ChainedHandshakeStatus?
        let reason: HandshakeQueryReason
    }

    /// One-shot resume guard: the message reply and the timeout race to resume the continuation; the
    /// first wins and the other no-ops, so it resumes exactly once (never twice, never zero times).
    /// `@unchecked Sendable` — the `NSLock` serialises the two call sites. (Kilo #556)
    private final class HandshakeReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HandshakeQueryResult, Never>?

        init(_ continuation: CheckedContinuation<HandshakeQueryResult, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: LavaSecAppGroup.ChainedHandshakeStatus?, reason: HandshakeQueryReason) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: HandshakeQueryResult(reply: value, reason: reason))
        }
    }

    /// Prompt chained-handshake status for the connect-flow gate + the "Connecting…" surface. Sends
    /// the lightweight `chainedHandshakeStatusMessage` (no mirror/persist tunnel-side) and decodes the
    /// reply. `nil` = no active session, the message failed, or the reply timed out; callers treat
    /// `nil` as unavailable, never as current confirmation. The reducer retains its old
    /// watermark only to validate a subsequent fresh same-runner reply; affirmative runner
    /// loss and counter regression still invalidate that proof. Background-spanning polls
    /// are cancelled before reduction, because their deadline is not an observation.
    func queryChainedHandshakeStatus() async -> LavaSecAppGroup.ChainedHandshakeStatus? {
        await queryChainedHandshakeObservation().reply
    }

    func queryChainedHandshakeObservation(reloadMissingManager: Bool = true) async -> HandshakeQueryResult {
        #if targetEnvironment(simulator)
        return .init(reply: nil, reason: .sessionUnavailable)
        #else
        chainedHandshakeQuerySequence &+= 1
        let query = chainedHandshakeQuerySequence
        let startedAt = ProcessInfo.processInfo.systemUptime
        if reloadMissingManager, tunnelManager == nil {
            tunnelManager = try? await loadExistingTunnelManager()
        }

        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
              isProtectionEnabledStatus(session.status)
        else {
            logVPNDebugEvent("chained-query-unavailable", details: [
                "query": String(query), "reason": "session-unavailable"
            ])
            return .init(reply: nil, reason: .sessionUnavailable)
        }
        let connectedAt = session.connectedDate
        let expectedConfiguration = configuration

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<HandshakeQueryResult, Never>) in
            let box = HandshakeReplyBox(continuation)
            // Bounded: the NE may be jetsammed mid-request and never call the reply handler, so a
            // deadline resumes nil to keep the poll loop alive (Kilo #556).
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.chainedHandshakeQueryTimeout) {
                box.resume(nil, reason: .timeout)
            }
            do {
                try session.sendProviderMessage(
                    Data(LavaSecAppGroup.chainedHandshakeStatusMessage.utf8)
                ) { response in
                    let reply = LavaSecAppGroup.ChainedHandshakeStatus.decode(response)
                    box.resume(reply, reason: reply == nil ? .invalidReply : .reply)
                }
            } catch {
                box.resume(nil, reason: .sendFailed)
            }
        }
        guard !Task.isCancelled, tunnelManager?.connection === session,
              isProtectionEnabledStatus(session.status), session.connectedDate == connectedAt,
              configuration == expectedConfiguration else {
            return .init(reply: nil, reason: .sessionUnavailable)
        }
        if result.reply == nil {
            logVPNDebugEvent("chained-query-unavailable", details: [
                "query": String(query), "reason": result.reason.rawValue,
                "elapsedMs": String(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)),
                "cancelled": String(Task.isCancelled),
                "applicationActive": String(UIApplication.shared.applicationState == .active)
            ])
        }
        return result
        #endif
    }

    var catalogCacheURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(
            LavaSecAppGroup.catalogCacheDirectoryName,
            isDirectory: true
        )
    }

    /// Cross-process lock for the pending-Focus-switch marker (LAV-100 Phase 4): the foreground reconcile's
    /// `clearIfMatches` takes the SAME lock the App Intents extension's `record` does, so an extension record
    /// can't interleave a clear's read→remove (Codex P2). Third party on this flock: the catalog-refresh
    /// BGTask drain (`BackgroundPendingSwitchDrain`) clears moot markers and re-records via the engine under
    /// the same lock file — reason about marker interleavings with all THREE participants.
    var pendingFilterSwitchMarkerLockURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.pendingFilterSwitchMarkerLockFilename)
    }

    var configurationURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.configurationFilename)
    }

    var filterLibraryURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename)
    }

    // diagnosticsURL / diagnosticsControlURL moved to DiagnosticsController.swift with
    // the store lifecycle + clear flows (Phase D4 peel); the uptime mirror above derives
    // the diagnostics path inline.

    var networkActivityLogURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.networkActivityLogFilename)
    }

    func modificationDate(for url: URL?) -> Date? {
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

    var tunnelProviderBundleIdentifier: String {
        let appBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.lavasec.app"
        return "\(appBundleIdentifier).tunnel"
    }

    func isProtectionEnabledStatus(_ status: NEVPNStatus) -> Bool {
        ProtectionLifecyclePolicy.isProtectionEnabled(status.protectionLifecycleStatus)
    }

    func isProtectionStopPendingStatus(_ status: NEVPNStatus) -> Bool {
        ProtectionLifecyclePolicy.isStopPending(status.protectionLifecycleStatus)
    }

    func isProtectionTransitionStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .reasserting, .disconnecting:
            true
        default:
            false
        }
    }

    private func isProtectionStartPendingStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .reasserting:
            true
        default:
            false
        }
    }

    func isLocalProtectionUptimeStatus(_ status: NEVPNStatus) -> Bool {
        ProtectionLifecyclePolicy.isUptimeActive(status.protectionLifecycleStatus)
    }

    static func vpnErrorMessage(prefix: String, error: Error) -> String {
        // User-facing, self-contained errors (e.g. the over-budget blocklist
        // message) are shown verbatim without the technical domain/code suffix.
        // Composition goes through format KEYS so locales control the separator
        // (French spacing, CJK full-width colon); production call sites pass an
        // already-localized prefix, QA-only sites keep their raw English one.
        if let preparationError = error as? FilterSnapshotPreparationError {
            return "%@: %@".lavaLocalizedFormat(prefix, preparationError.localizedDescription)
        }
        let nsError = error as NSError
        return "%@: %@ (%@ %d).".lavaLocalizedFormat(
            prefix,
            nsError.localizedDescription,
            nsError.domain,
            nsError.code
        )
    }
}
