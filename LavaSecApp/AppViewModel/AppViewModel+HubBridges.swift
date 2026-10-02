import Darwin
import Foundation
import Combine
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices

// MARK: - Catalog sync bridge

// CatalogController owns only single-flight/cancellation and sync presentation. The one bridge
// method `applyCatalogSyncResult` (AppViewModel+LavaGuardProgress.swift) remains the complete
// AppViewModel transaction boundary for shared catalog metadata,
// artifact publication, persistence, cache recovery, tunnel notification, warming, and protection.
extension AppViewModel: CatalogSyncTransactionBridging {}

// MARK: - Backup hub bridge

// The hub side of the Phase D1 backup peel (BackupController owns the backup feature;
// see BackupHubBridging's protocol doc in BackupController.swift). Conformance lives in
// this file, one of the files of the `AppViewModel` class, so the bridge reaches the hub's
// state directly — the compiler-enforced
// boundary is the protocol surface, which is exactly the backup cluster's historical
// non-backup couplings: payload building (configuration + catalogVersion + library),
// the ExclusiveReplacementGate tokens, Supabase session access + the accountAuthState
// mirror, and the tunnel snapshot notify. Since the Phase D3 account peel the session
// and account state live on AccountController, so the account-facing members here are
// one-line delegations through `account` — the bridge signatures (and their callers in
// BackupController) are unchanged, and the hub remains the single routing point.
extension AppViewModel: BackupHubBridging {
    var currentBackupAccountID: String? {
        account.accountAuthState.connections.all.first?.session.userID
    }

    var isAccountSignedIn: Bool {
        account.isAccountSignedIn
    }

    var accountEmailForBackupPasskey: String? {
        account.accountEmailForBackupPasskey
    }

    func makeBackupConfigurationPayload() -> BackupConfigurationPayload {
        BackupConfigurationPayload(
            configuration: configuration,
            catalogVersionHint: catalogVersion,
            filterLibrary: library
        )
    }

    func beginConfigurationReplacement() -> Int {
        configurationReplacementGate.begin()
    }

    func isConfigurationReplacementCurrent(_ token: Int) -> Bool {
        configurationReplacementGate.isCurrent(token)
    }

    // Raw pass-throughs + a separate state mirror (NOT a combined call-then-mirror), so
    // the controller preserves the pre-peel `accountAuthState = accountAuthService.state`
    // ordering exactly at every call site. Delegated to AccountController (which owns
    // AccountAuthService since Phase D3) with identical semantics; the service-facing
    // bodies live on the controller's hub-bridge backing section.
    func currentBackupSession() async throws -> BackupAccountSession? {
        try await account.currentBackupSession()
    }

    func refreshCurrentBackupSession() async throws -> BackupAccountSession? {
        try await account.refreshCurrentBackupSession()
    }

    func mirrorAccountAuthState() {
        account.mirrorAccountAuthState()
    }

    func notifyTunnelSnapshotUpdatedAfterRestore() async {
        await notifyTunnelSnapshotUpdated()
    }

    func prepareBackupRestorePlan(_ payload: BackupConfigurationPayload) throws -> BackupRestorePlan {
        try BackupRestorePlan(
            payload: payload, currentConfiguration: configuration, currentLibrary: library,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        )
    }

    func validateBackupRestorePlan(_ plan: BackupRestorePlan, resolverChangeConfirmed: Bool) throws {
        guard !sharedStateUnavailableAtLoad, let containerURL = LavaSecAppGroup.containerURL else {
            throw LavaSecAppError.sharedStateUnavailable
        }
        guard SharedFilterStatePersistence.onDiskConfigurationGeneration(
            at: containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename)
        ) == plan.previousConfiguration.configurationGeneration else {
            throw BackupRestorePlanError.staleReview
        }
        try plan.validateConfirmation(
            currentConfiguration: configuration, currentLibrary: library,
            resolverChangeConfirmed: resolverChangeConfirmed
        )
    }

    /// Applies the confirmed, validated pair through the existing config-first persistence owner.
    func applyReviewedBackup(
        _ plan: BackupRestorePlan, replacementToken: Int, resolverChangeConfirmed: Bool
    ) async throws -> BackupRestoreCompletion {
        do {
            guard isConfigurationReplacementCurrent(replacementToken) else {
                throw EncryptedBackupError.supersededByConcurrentConfigurationChange
            }
            try validateBackupRestorePlan(plan, resolverChangeConfirmed: resolverChangeConfirmed)
        } catch {
            throw ReviewedBackupApplyError.rejectedBeforeWrite(error)
        }
        let configurationBeforeRestore = configuration
        let libraryBeforeRestore = library
        let draftsBeforeRestore = filterDrafts.sessions
        configuration = plan.configuration
        library = plan.library
        // Restore replaces the whole library, so every per-filter draft + the detail target are
        // stale — wipe them so a preserved edit can't overwrite the just-restored state.
        filterDrafts.resetSessions()
        // Lift reseed suppression in memory so persistence can reseal the reviewed backup.
        // Clear its durable marker only after the pair lands (INV-PERSIST-2).
        // pinned: RebootFirstUnlockGuardSourceTests.testAutomaticBackupIsSuppressedWhileLibraryOriginatesFromLaunchReseed
        let suppressionBeforeRestore = libraryOriginatesFromLaunchReseed
        libraryOriginatesFromLaunchReseed = false
        // Config-first persistence retains device-global fields if the library write fails.
        // Backup writers stay paused under the controller's maintenance lease; the
        // reviewed envelope is committed only after this method returns successfully.
        // Artifact publication can throw after the pair lands, so generation advancement,
        // rather than the thrown error alone, determines durable ownership (INV-PERSIST-2).
        // pinned: RebootFirstUnlockGuardSourceTests.testAutomaticBackupIsSuppressedWhileLibraryOriginatesFromLaunchReseed
        let generationBeforeRestorePersist = configuration.configurationGeneration
        var completion = BackupRestoreCompletion.complete
        do {
            try await persistSharedState(
                prioritizesConfigurationDurability: true,
                expectedConfigurationGeneration: plan.previousConfiguration.configurationGeneration
            )
        } catch {
            if configuration.configurationGeneration > generationBeforeRestorePersist {
                // The restored pair IS durably down (a post-pair step failed) — the on-disk
                // library is user-authoritative, so the suppression and its marker lift
                // despite the error.
                clearLibraryOriginatesFromLaunchReseed()
                if !configuration.keepLavaGuardProgress { clearSudokuGameState() }
                completion = .filteringNeedsAttention
            } else {
                // No complete pair was confirmed. Retain reseed suppression; a config-only
                // partial write is reconciled by the normal next-launch migration.
                libraryOriginatesFromLaunchReseed = suppressionBeforeRestore
                if error is SharedFilterStatePersistence.StaleBaseGenerationError {
                    configuration = configurationBeforeRestore
                    library = libraryBeforeRestore
                    filterDrafts.restoreSessions(draftsBeforeRestore)
                    throw ReviewedBackupApplyError.rejectedBeforeWrite(BackupRestorePlanError.staleReview)
                }
                throw error
            }
        }
        if !configuration.keepLavaGuardProgress { clearSudokuGameState() }
        // The restored pair is durably on disk — drop the suppression and its marker.
        clearLibraryOriginatesFromLaunchReseed()
        // INV-TIER-1: a restore replaces the selection wholesale with no compile on the path, so
        // a backup written under Plus (or from a device whose lists have since grown) can land an
        // over-budget selection on this tier. The user's restored data is kept as-is — the
        // publish/reuse/serve gates keep it from ever being served — but surface the tier message
        // now so the refusal is explained rather than discovered. Recompute the compiled count for
        // the RESTORED enabled set first: without this the check reads the PRE-restore state and
        // can show a false tier error to a user who just restored a smaller, fitting selection.
        // Sources the restore enabled but this device hasn't cached yet contribute nothing — an
        // under-count, so the residual failure mode is only a delayed message (the follow-up sync
        // re-runs the same check on its own status path), never a false one.
        refreshCompiledBlocklistRuleCount()
        reconcileTierBudgetStatusAfterPlanOrRestoreChange()
        return completion
    }
}

// MARK: - LavaSecurity+ hub bridge

// The hub side of the Phase D2 billing peel (LavaSecurityPlusController owns the
// paywall/billing feature; see LavaSecurityPlusHubBridging's protocol doc in
// LavaSecurityPlusController.swift). Conformance lives in this file so the bridge can
// reach the hub's own state — the compiler-enforced boundary is the protocol
// surface, which is exactly the billing cluster's historical non-billing couplings:
// the configuration's paid-plan flag + its persist-only funnel, and Supabase session
// access + the accountAuthState mirror. The session pass-throughs
// (currentBackupSession / refreshCurrentBackupSession / mirrorAccountAuthState) are
// requirements shared with BackupHubBridging and are implemented ONCE in that
// conformance above — Swift satisfies both protocols with the same members, keeping
// one canonical Supabase identity path.
extension AppViewModel: LavaSecurityPlusHubBridging {
    var hasLavaSecurityPlus: Bool {
        configuration.hasLavaSecurityPlus
    }

    /// Applies the entitlement outcome to the persisted plan. The paid flag drives
    /// app-side tier limits and UI; the tunnel never reads isPaid for FEATURE gating,
    /// but it does enforce the derived `limits.maxFilterRules` as the INV-TIER-1
    /// serve cap. Persist the flag so the status survives launches, but do NOT signal
    /// a configuration reload — that reapplies tunnel network settings (a visible
    /// reconnect) and would fire spuriously on every entitlement change. (Moved with
    /// the code from the pre-peel applyLavaSecurityPlusEntitlement; the controller
    /// keeps the do/catch + paywall message semantics around this call.)
    func persistPaidPlanFlag(_ isPaid: Bool) throws {
        // ROLLED BACK ON A FAILED WRITE, like every other in-memory mutation that precedes a
        // persist here. Without it this method leaves `configuration` describing a write that
        // did not happen: `isPaid` false and `chainedUpstreamEnabled` cleared in memory while
        // disk still says otherwise. Staging's own re-check then reads the in-memory value,
        // reports "chaining was switched off" and tells the operator to stage again — about a
        // rotation that IS still enabled on disk and will latch at the next restart
        // (Codex, PR #519). Rolling back is the fix rather than having staging re-read the
        // durable state, because the divergence is what is wrong: the same argument the
        // staging path's own rollback comment makes.
        let previousIsPaid = configuration.isPaid
        let previousChainedUpstreamEnabled = configuration.chainedUpstreamEnabled
        configuration.isPaid = isPaid
        // INV-CHAIN-2 convergence. A lapse makes chaining unavailable, and a stored flag that
        // can never be honoured is worse than none: Settings would read on while nothing
        // happens. Reconcile BEFORE the persist below so the lapse and the disable land as a
        // single atomic configuration write — a second write here would mean a second
        // generation bump, a second cross-process lock, and a second backup schedule for one
        // Bool, and would leave a window where the flag outlives the entitlement on disk.
        //
        // Safety does not depend on this. The tunnel's start latch refuses chained mode on an
        // ineligible device independently (INV-CHAIN-1), so this is convergence of the stored
        // preference, not enforcement.
        // pinned: ChainedUpstreamReconcileSourceTests.testALapseClearsTheChainingFlagInTheSameWrite
        reconcileChainedUpstreamAfterEligibilityChange(reason: "plan-changed")
        do {
            try persistConfigurationOnly()
        } catch {
            // READ BEFORE RESTORING. The reconcile emits `chained-upstream-disabled` exactly
            // when it turned the flag off, which is visible only while the flag is still off
            // — after the restore, `previousChainedUpstreamEnabled && !configuration...` is
            // `x && !x` and can never fire. The first version of this retraction did the
            // check after the restore and was dead code: it claimed to fix the misleading
            // log and changed nothing (Codex and Kilo, PR #519, independently).
            //
            // Not simply `previousChainedUpstreamEnabled` either, which is the tempting
            // one-token fix: `persistPaidPlanFlag(true)` also runs this reconcile, and an
            // already-enabled upstream that stays enabled logs no disable — so that
            // condition would retract an event nobody wrote.
            let didDisable = previousChainedUpstreamEnabled && !configuration.chainedUpstreamEnabled
            configuration.isPaid = previousIsPaid
            configuration.chainedUpstreamEnabled = previousChainedUpstreamEnabled
            // AND RETRACT THE BREADCRUMB. `reconcileChainedUpstreamAfterEligibilityChange`
            // has already written `chained-upstream-disabled` to the device log by this
            // point, so a rollback that restores only the flags leaves diagnostics asserting
            // a disable that did not survive — misdirecting an investigation of this exact
            // failed write (Codex, PR #519). A compensating event rather than deferring the
            // original: the reconcile mutates and the CALLER persists, so it cannot know
            // whether the write landed, and every other caller would have to learn to log.
            // The log is append-only, so retraction is the honest shape.
            if didDisable {
                logVPNDebugEvent("chained-upstream-disable-rolled-back", details: [
                    "reason": "plan-changed",
                ])
            }
            throw error
        }
        // INV-TIER-1 downgrade reconciliation: a lapse shrinks the budget under the
        // ACTIVE filter with no compile anywhere on the path (this call is the entire
        // downgrade), so surface the over-budget state on the existing status surface
        // now — deliberately deferred-in-effect, still no reload/reconnect: the
        // publish/reuse/serve gates make the cap bite at the next natural compile
        // point, this line just tells the user why before that happens. An
        // already-resident tunnel snapshot keeps serving until that point (the
        // INV-TIER-1 resident carve-out) — extra filtering, never fail-open.
        reconcileTierBudgetStatusAfterPlanOrRestoreChange()
    }
}

// MARK: - Account hub bridge

// The hub side of the Phase D3 account peel (AccountController owns sign-in/sign-out/
// deletion and AccountAuthService; see AccountHubBridging's protocol doc in
// AccountController.swift). These hooks are the account cluster's historical
// cross-FEATURE reactions, kept hub-orchestrated so feature controllers never
// reference each other: the account controller reports the event; the hub routes it
// to the affected features in the exact pre-peel order.
extension AppViewModel: AccountHubBridging {
    /// Sign-in success follow-ups, pre-peel order preserved: upload any local
    /// encrypted backup that was waiting for a session, refresh metadata for the
    /// resulting account even when there was nothing to upload, THEN push the
    /// current StoreKit entitlement to the server sync.
    func accountDidSignIn() async {
        await backup.uploadPendingEncryptedBackupIfPossible()
        await backup.refreshRemoteBackupStatus()
        await plus.syncCurrentLavaSecurityPlusEntitlementIfPossible()
    }

    /// Complete pending backup Off before its account disappears, and keep backup
    /// writers paused until the account operation has finished.
    func accountWillBeginDeletion(accountID: String) async throws {
        try await backup.prepareForAccountDeletion(accountID: accountID)
    }

    func accountWillCompleteDeletion(accountID: String) {
        backup.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: accountID)
    }

    func accountDidFinishDeletion() async {
        await backup.finishAccountDeletionMaintenance()
    }

    /// Sign-out clears recurring-upload consent before refreshing presentation;
    /// signing back in requires a fresh Automatic Backup opt-in.
    func reloadEncryptedBackupStateAfterAccountChange() {
        if !account.isAccountSignedIn {
            backup.setAutomaticBackupEnabled(false)
        }
        backup.loadEncryptedBackupState()
        Task { await backup.refreshRemoteBackupStatus() }
    }
}

// MARK: - Diagnostics hub bridge

// The hub side of the Phase D4 diagnostics/bug-report peel (DiagnosticsController owns
// the store lifecycle, clears, bug-report draft/send, and rage-shake routing; see
// DiagnosticsHubBridging's protocol doc in DiagnosticsController.swift). Conformance
// lives in this file so the bridge can reach the hub's own state — the
// compiler-enforced boundary is the protocol surface, which is exactly the diagnostics
// cluster's historical non-diagnostics couplings: the two config keep-flags (read +
// persist-only write), the VPN-status file-ownership signal, tunnel messaging, the
// vpnMessage banner, the cross-feature clears (network activity, LavaGuard progress),
// the report-surfaces refresh, the compiled-snapshot capture, and the wide-hub-state
// bug-report bundle ASSEMBLY kept hub-side by design (bridge-width judgement: peeling
// it would have needed a sprawling read surface — configuration, catalog, health,
// status, rule counts — for one function). `refreshReports`,
// `clearNetworkActivityLog(notifyTunnel:)`, `clearLavaGuardProgress()`, and
// `isAccountDeveloper` are witnessed by the hub's existing members in the class's other files.
extension AppViewModel: DiagnosticsHubBridging {
    var keepsDomainDiagnostics: Bool {
        configuration.keepDomainDiagnostics
    }

    var keepsFilteringCounts: Bool {
        configuration.keepFilteringCounts
    }

    /// True while the tunnel may still write diagnostics.json (UX-4 / PST-3): the whole
    /// NON-stopped lifecycle, not just `.connected` — see the ownership comment in the
    /// controller's `refreshDiagnostics`.
    var isProtectionStopPending: Bool {
        isProtectionStopPendingStatus(vpnStatus)
    }

    /// Writes the keep-counts flag and persists config-only. The flag only gates the
    /// app/tunnel's local-log recording; the controller keeps the reload-message +
    /// clear semantics around this call (moved with the code from the pre-peel
    /// setKeepFilteringCounts).
    func persistKeepFilteringCountsFlag(_ keepFilteringCounts: Bool) throws {
        configuration.keepFilteringCounts = keepFilteringCounts
        try persistConfigurationOnly()
    }

    /// Same funnel for the keep-domain-history flag (pre-peel setKeepDomainDiagnostics).
    func persistKeepDomainDiagnosticsFlag(_ keepDomainDiagnostics: Bool) throws {
        configuration.keepDomainDiagnostics = keepDomainDiagnostics
        try persistConfigurationOnly()
    }

    /// Relay onto the hub-owned provider-message channel (the full-signature
    /// sendTunnelMessage — internal since the class spans files — keeps its default fallback
    /// copy + latency tracing; the explicit
    /// nil operationID selects that overload — same defaults as every pre-peel call
    /// site — instead of recursing into this wrapper).
    func sendTunnelMessage(_ message: String) async {
        await sendTunnelMessage(message, operationID: nil)
    }

    /// The clears' failure surface stays the hub's banner (vpnMessage), exactly where
    /// the pre-peel clear flows wrote it.
    func presentVPNMessage(_ message: String, isError: Bool) {
        vpnMessage = message
        vpnMessageIsError = isError
    }

    func currentFilterSnapshot() -> FilterSnapshot {
        currentSnapshot()
    }

    /// The bug-report bundle ASSEMBLY — a SNAPSHOT of wide hub state, kept hub-side by
    /// design (Phase D4 bridge-width judgement). The controller passes in everything it
    /// owns (`BugReportBundleInputs`): the prepared heavy inputs (UR-5 cache) plus the
    /// live local-observability reads (its DiagnosticsStore, the LAV-92/93 gap record,
    /// the incident-ledger report view). Body otherwise verbatim from the pre-peel
    /// makeBugReportBundle(context:inputs:).
    func makeBugReportBundle(
        context: BugReportContext,
        inputs: BugReportBundleInputs
    ) -> BugReportBundle {
        let identity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: currentCatalog
        )
        let snapshotVersion = String(identity.fingerprint.prefix(12))
        let affectedSiteDecision = BugReportAffectedSiteFilterDecision.make(
            rawAffectedSite: context.normalizedAffectedSite,
            snapshot: inputs.snapshot
        )

        return BugReportBundle(
            context: context,
            app: BugReportAppSnapshot(
                version: Self.bundleInfoValue("CFBundleShortVersionString"),
                build: Self.bundleInfoValue("CFBundleVersion")
            ),
            device: BugReportDeviceSnapshot(
                iosVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                deviceFamily: Self.deviceFamilyDescription(UIDevice.current.userInterfaceIdiom),
                locale: Locale.current.identifier
            ),
            vpn: BugReportVPNSnapshot(
                status: vpnStatusReportDescription(vpnStatus),
                resolverPreset: configuration.resolverDiagnosticDisplayName,
                health: tunnelHealth
            ),
            filters: BugReportFilterSummary(
                catalogVersion: catalogVersion,
                enabledListIDs: configuration.enabledBlocklistIDs.sorted(),
                snapshotVersion: snapshotVersion,
                compiledRuleCount: compiledRuleCount,
                blocklistRuleCount: compiledBlocklistRuleCount,
                customBlocklistCount: configuration.customBlocklists.count,
                enabledCustomBlocklistCount: configuration.customBlocklists.filter {
                    configuration.enabledBlocklistIDs.contains($0.id)
                }.count,
                affectedSiteDecision: affectedSiteDecision
            ),
            diagnostics: inputs.diagnostics,
            localHistoryEnabled: configuration.keepDomainDiagnostics,
            debugLogEntries: inputs.debugLogEntries,
            selfReconnectTimes: inputs.selfReconnectTimes,
            // Privacy-safe Focus-switch diagnostic (LAV-100 Phase 4): the extension records the last
            // attempt's outcome to the shared app group, so a closed-app failure is debuggable from the
            // (Release) bug report without a device or the QA device log.
            lastFocusSwitch: focusDiagnosticsUnderConsent.last,
            lastFocusFailure: focusDiagnosticsUnderConsent.failure,
            selfReconnectGap: inputs.selfReconnectGap,
            recentIncidents: inputs.recentIncidents
        )
    }
}

// MARK: - Customization hub bridge

// The hub side of the Phase D5 customization peel (CustomizationController owns the
// preference cluster; see CustomizationHubBridging's protocol doc in
// CustomizationController.swift). Conformance lives in this file so the bridge can
// reach the hub's own state — the compiler-enforced boundary is the protocol
// surface, which is exactly the customization cluster's historical non-customization
// couplings: the configuration's Plus flag / unlock ledger / keep-progress flag and the
// hub-owned LavaGuard progress (availability inputs), the Live Activity device-class
// gate + reconcile, and the contextual notification-permission request.
// `hasLavaSecurityPlus` (shared with LavaSecurityPlusHubBridging), `lavaGuardProgress`
// (the stored @Published in AppViewModel.swift), `canOfferLiveActivities`, and
// `reconcileLiveActivity()` (AppViewModel+LiveActivity.swift)
// are witnessed by the hub's existing members.
extension AppViewModel: CustomizationHubBridging {
    var lavaGuardUnlocks: LavaGuardAchievementLedger {
        configuration.lavaGuardUnlocks
    }

    var keepsLavaGuardProgress: Bool {
        configuration.keepLavaGuardProgress
    }

    /// The contextual permission request for an enabled Customization → Notifications
    /// toggle — the same hub-owned controller onboarding's request goes through, so
    /// there is one notification-authorization path.
    @discardableResult func requestNotificationAuthorization() async -> Bool {
        await protectionUserNotifications.requestAuthorization()
    }
}

// Read-only inputs for the independently owned draft editor.
extension AppViewModel: FilterDraftContextProviding {
    func draftRuleBudgetRejection(for ids: Set<String>) -> String? {
        enabledIDsExceedSoftRuleBudget(ids) ? filterRuleBudgetMessage() : nil
    }

    func draftCustomBlocklistDisplayKey(for source: CustomBlocklistSource) -> String {
        customBlocklistDisplayKey(for: source)
    }
}

// MARK: - Library presentation bridge

// Read-only state plus complete existing native operations. The screen never gets
// a configuration setter, write lock, replacement token, or persistence primitive.
extension AppViewModel: FilterLibraryHubBridging {
    func applyLibraryFilter(id: String) async {
        await switchToFilter(id: id, stampsForegroundSwitch: true)
    }
    var libraryMaximumFilters: Int { configuration.limits.maxFilters }
    var libraryHasPlus: Bool { configuration.hasLavaSecurityPlus }
    var libraryChanges: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
}
