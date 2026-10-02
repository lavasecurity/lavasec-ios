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
    // MARK: - App Store review prompting
    //
    // All three review anchors (protection-on, filter-update, activity-viewing) funnel through the
    // pure `ReviewPromptPolicy`; the app keeps only this thin orchestration. Bookkeeping lives in
    // `UserDefaults.standard` — app-only, like `hasSeenLavaOnboarding`, never the app group.
    // Design: lavasec-infra/plans/2026-07-16-app-store-review-prompt-plan.md
    // pinned: ReviewPromptWiringSourceTests.testEvaluationGoesThroughTheSharedPolicyAndAppOnlyDefaults

    private var reviewPromptDefaults: UserDefaults { .standard }

    /// Records a user-initiated successful turn-on and evaluates the protection-on anchor. Called from
    /// the VPN-status funnel ONLY on a fresh `.connected` transition the user initiated (guarded by the
    /// `awaitsProtectionOnHaptic` arm) — never an automatic on-demand reconnect.
    func recordUserInitiatedProtectionOnForReview() {
        var state = ReviewPromptStateStorage.load(from: reviewPromptDefaults)
        state.successfulProtectionOns += 1
        ReviewPromptStateStorage.save(state, to: reviewPromptDefaults)
        evaluateReviewPrompt(for: .protectionOn, state: state)
    }

    /// Evaluates the filter-update anchor after a foreground draft apply that ADDED protection (a
    /// curated blocklist or blocked domain — never a paid custom list, and never an added allowed
    /// domain, which is an EXCEPTION that weakens filtering; see `reviewFilterUpdateAddedProtection`).
    func noteFilterUpdatedReviewMoment() {
        evaluateReviewPrompt(
            for: .filterUpdated,
            state: ReviewPromptStateStorage.load(from: reviewPromptDefaults)
        )
    }

    /// Evaluates the activity-viewing anchor. `ActivityView` enforces the foreground dwell; the policy
    /// enforces the query-volume + block-rate magnitude off the on-screen summary.
    func noteActivityViewingReviewMoment(totalQueries: Int, blockRate: Double) {
        evaluateReviewPrompt(
            for: .viewingActivity(totalQueries: totalQueries, blockRate: blockRate),
            state: ReviewPromptStateStorage.load(from: reviewPromptDefaults)
        )
    }

    private func evaluateReviewPrompt(for moment: ReviewAhaMoment, state: ReviewPromptState) {
        guard ReviewPromptPolicy.shouldRequest(
            for: moment,
            state: state,
            hasCompletedOnboarding: hasCompletedOnboarding,
            now: Date()
        ) else {
            return
        }
        // Only ARM here — do NOT spend the budget yet. An eligible moment can be armed from an async
        // path (a filter apply or VPN connect finishing) after the user has left the app; the timestamp
        // that spends the 90-day/annual budget is recorded in `markReviewRequestPresented`, when the
        // native prompt is actually issued in an active scene. So a request armed while backgrounded and
        // never presented (app killed first) never burns a slot. (Codex review #406.)
        pendingReviewRequest = true
    }

    /// Records that the native review prompt was actually issued (RootView calls this only in an active
    /// scene) and disarms the one-shot. The budget timestamp is spent HERE, not at arm time, so StoreKit
    /// silently dropping a request fired with no active scene can never put the user on the throttle
    /// without seeing the sheet. pinned: ReviewPromptWiringSourceTests.testEvaluationGoesThroughTheSharedPolicyAndAppOnlyDefaults
    func markReviewRequestPresented() {
        // The budget-spending timestamp must co-locate with the only legitimate trigger — an armed
        // request actually presented in an active scene. Guard on `pendingReviewRequest` so a future
        // caller (a debug menu, a test harness, or a moved call) can't append a timestamp with no UI
        // arm, silently spending the 90-day/annual budget and throttling a later real anchor (OCR
        // review on lavasec-ios#69).
        guard pendingReviewRequest else { return }
        var state = ReviewPromptStateStorage.load(from: reviewPromptDefaults)
        state.promptTimestamps.append(Date())
        ReviewPromptStateStorage.save(state, to: reviewPromptDefaults)
        pendingReviewRequest = false
    }

    func scheduleProtectionNotificationIfNeeded() {
        guard vpnStatus == .connected else {
            return
        }

        protectionUserNotifications.scheduleIfNeeded(
            assessment: protectionConnectivityAssessment,
            health: tunnelHealth
        )
    }

    func appendAppNetworkActivity(_ action: NetworkActivityUserAction) {
        appendNetworkActivity(.userAction(action))
    }

    func appendNetworkActivity(_ event: NetworkActivityEvent) {
        guard configuration.keepNetworkActivity else {
            return
        }

        guard let networkActivityLogURL else {
            return
        }

        let entry = NetworkActivityLogEntry(
            timestamp: Date(),
            event: event,
            lavaState: LavaStateSnapshot(
                protectionStatus: protectionTitle,
                connectivityStatus: protectionConnectivityAssessment.severity.diagnosticLabel,
                networkKind: tunnelHealth.networkKind,
                networkPathIsSatisfied: tunnelHealth.networkPathIsSatisfied,
                resolverDisplayName: configuration.resolverPreset.displayName,
                resolverTransport: tunnelHealth.lastResolverTransport,
                fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
                deviceDNSFallbackActive: protectionConnectivitySeverity == .usingDeviceDNSFallback,
                usesEncryptedDeviceDNSFallback: configuration.usesEncryptedDeviceDNSFallback,
                // A DEVICE-DNS primary's live fallback is the ENCRYPTED one, and it carries its
                // own severity — `deviceDNSFallbackActive` above tracks `.usingDeviceDNSFallback`,
                // which that episode never sets (Codex P2, PR #597).
                encryptedFallbackActive: protectionConnectivitySeverity == .usingEncryptedFallback,
                // The SELECTED preset's transport, not `tunnelHealth.lastResolverTransport` above —
                // the state line must name the toggle the DNS page showed, and that follows the
                // selection rather than whatever transport the last resolution happened to use.
                configuredResolverTransport: configuration.resolverPreset.transport
            )
        )
        NetworkActivityLogPersistence.append(entry, to: networkActivityLogURL)
        refreshNetworkActivityLog(force: true)
    }

    static let lavaGuardUsageAccrualInterval: TimeInterval = 60

    func synchronizeLocalProtectionUptime(currentStatus: NEVPNStatus) {
        synchronizeLavaGuardProgress(currentStatus: currentStatus)

        guard configuration.keepFilteringCounts else {
            return
        }

        // Derived inline since the Phase D4 peel moved the shared `diagnosticsURL`
        // computed to DiagnosticsController with the store's refresh lifecycle; this
        // uptime mirror is the hub's only remaining direct reader of the file. The
        // store writes below publish onto `reports.diagnostics` (hub→controller is
        // the allowed direction), exactly as they published the pre-peel hub property.
        guard let diagnosticsURL = LavaSecAppGroup.containerURL?
            .appendingPathComponent(LavaSecAppGroup.diagnosticsFilename) else {
            return
        }

        let isRunning = isLocalProtectionUptimeStatus(currentStatus)
        guard lastObservedProtectionUptimeIsRunning != isRunning else {
            return
        }

        var store = DiagnosticsPersistence.load(from: diagnosticsURL)
        lastObservedProtectionUptimeIsRunning = isRunning

        if isRunning {
            guard !store.isLocalProtectionUptimeActive else {
                reports.diagnostics = store
                return
            }
            store.startLocalProtectionUptime()
        } else {
            guard store.isLocalProtectionUptimeActive else {
                reports.diagnostics = store
                return
            }
            store.stopLocalProtectionUptime()
        }

        reports.diagnostics = store
        try? DiagnosticsPersistence.save(store, to: diagnosticsURL)
    }
}
