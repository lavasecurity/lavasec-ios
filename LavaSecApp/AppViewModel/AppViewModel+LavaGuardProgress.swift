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
    // MARK: - LavaGuard progress

    func synchronizeLavaGuardProgress(currentStatus: NEVPNStatus) {
        guard canUseProtectedPreferences, configuration.keepLavaGuardProgress else {
            return
        }

        let isRunning = isLocalProtectionUptimeStatus(currentStatus)
        let now = Date()
        let runningStateChanged = lastLavaGuardUsageIsRunning != isRunning
        guard runningStateChanged
            || now.timeIntervalSince(lastLavaGuardUsageAccrualAt) >= Self.lavaGuardUsageAccrualInterval
        else {
            return
        }
        lastLavaGuardUsageIsRunning = isRunning
        lastLavaGuardUsageAccrualAt = now

        var nextProgress = lavaGuardProgress
        var nextLedger = configuration.lavaGuardUnlocks
        nextProgress.synchronizeLocalProtectionUsage(
            isRunning: isRunning,
            ledger: &nextLedger
        )
        applyLavaGuardProgress(nextProgress, ledger: nextLedger)
    }

    // Internal (not private) since the Phase D4 peel: it is a DiagnosticsHubBridging
    // requirement — the diagnostics controller calls it right after a fresh store load
    // replaces `reports.diagnostics`, in the exact pre-peel slot.
    func refreshLavaGuardProgressFromDiagnostics() {
        guard canUseProtectedPreferences, configuration.keepLavaGuardProgress else {
            return
        }

        let usageDayKeys = reports.diagnostics.localProtectionUsageDayKeys()
        guard !usageDayKeys.isEmpty else {
            return
        }

        var nextProgress = lavaGuardProgress
        var nextLedger = configuration.lavaGuardUnlocks
        nextProgress.replaceQualifiedUsageDayKeys(
            nextProgress.qualifiedUsageDayKeys.union(usageDayKeys),
            ledger: &nextLedger
        )
        applyLavaGuardProgress(nextProgress, ledger: nextLedger)
    }

    private func applyLavaGuardProgress(
        _ nextProgress: LavaGuardProgress,
        ledger nextLedger: LavaGuardAchievementLedger
    ) {
        guard canUseProtectedPreferences else { return }
        let progressChanged = lavaGuardProgress != nextProgress
        let ledgerChanged = configuration.lavaGuardUnlocks != nextLedger

        guard progressChanged || ledgerChanged else {
            return
        }

        lavaGuardProgress = nextProgress
        if progressChanged {
            persistLavaGuardProgress()
        }

        if ledgerChanged {
            configuration.lavaGuardUnlocks = nextLedger
            do {
                try persistConfigurationOnly()
            } catch {
                vpnMessage = error.localizedDescription
                vpnMessageIsError = true
            }
        }
    }
}
