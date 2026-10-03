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
    // MARK: - Diagnostics & local log export

    // The clear flows (clearDiagnostics, clearDomainHistory, clearLocalFilteringCounts,
    // clearAllLocalLogs — including the incident-ledger/device-debug-log/gap-marker
    // wipes and their CON-1/#200 clear-ordering contract), the two diagnostics-coupled
    // keep-flag setters, and refreshDiagnostics live on `reports`
    // (DiagnosticsController) since the Phase D4 peel. The export archive below stays
    // hub-side by design (bridge-width judgement): it SNAPSHOTS wide hub state and
    // calls back into the controller for the pieces the controller owns.

    func makeLocalLogExportArchive(includeDomainHistory: Bool = false, generatedAt: Date = Date()) async throws -> LocalLogExportArchive {
        reports.refreshDiagnostics()
        refreshNetworkActivityLog(force: true)
        synchronizeLavaGuardProgress(currentStatus: vpnStatus)

        // Snapshot the Sendable inputs on the main actor, then build the archive OFF it. The
        // Opted-in Domain History streams page-by-page from the queue-confined DNSEventLog inside the
        // detached task, so a high-volume export neither freezes the UI (the CSV+ZIP encode ran
        // synchronously on @MainActor) nor materializes the full retained history on the main
        // thread (#340 review; the previous export accumulated every page into one array).
        let diagnostics = reports.diagnostics
        let domainHistory = includeDomainHistory ? reports.domainHistoryExportSource(at: generatedAt) : nil
        let networkActivityLog = networkActivityLog
        let lavaGuardProgress = lavaGuardProgress
        let lavaGuardUnlocks = configuration.lavaGuardUnlocks
        let deviceDebugLog = reports.loadDeviceDebugLogEntriesForExport()
        let metadata = makeLocalLogExportMetadata()

        return try await Task.detached(priority: .userInitiated) {
            try LocalLogExportArchive.make(
                diagnostics: diagnostics,
                domainHistory: domainHistory,
                networkActivityLog: networkActivityLog,
                lavaGuardProgress: lavaGuardProgress,
                lavaGuardUnlocks: lavaGuardUnlocks,
                deviceDebugLog: deviceDebugLog,
                metadata: metadata,
                generatedAt: generatedAt
            )
        }.value
    }

    // Build/environment provenance for the export manifest, from the same
    // Info.plist / device values the bug-report bundle uses. `source_revision`
    // (Info.plist LavaSourceRevision) is the field that pins an export to an
    // exact commit — empty on local builds, the 12-char SHA on release builds.
    private func makeLocalLogExportMetadata() -> LocalLogExportMetadata {
        LocalLogExportMetadata(
            appVersion: Self.bundleInfoValue("CFBundleShortVersionString"),
            build: Self.bundleInfoValue("CFBundleVersion"),
            sourceRevision: Self.bundleInfoValue("LavaSourceRevision"),
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            deviceFamily: Self.deviceFamilyDescription(UIDevice.current.userInterfaceIdiom),
            locale: Locale.current.identifier,
            catalogVersion: catalogVersion
        )
    }

    // The device debug-log reads (loadDeviceDebugLogEntriesForExport, the
    // rotation-aware deviceDebugLogGenerations) moved to DiagnosticsController
    // with the Phase D4 peel — the export assembly above calls back into it.

    func refreshNetworkActivityLog(force: Bool = false) {
        guard configuration.keepNetworkActivity else {
            clearNetworkActivityLog(notifyTunnel: false)
            return
        }

        guard let networkActivityLogURL else {
            networkActivityLogReadGate.reset()
            return
        }

        guard let modifiedAt = modificationDate(for: networkActivityLogURL) else {
            networkActivityLogReadGate.reset()
            networkActivityLog = NetworkActivityLog()
            return
        }

        if networkActivityLogReadGate.shouldRead(modifiedAt: modifiedAt, force: force) {
            // File changed: prune on disk and reload, capturing the pruned log and
            // its post-prune mtime atomically under the lock, so a tunnel append
            // landing mid-refresh is not silently marked as already read.
            let pruned = NetworkActivityLogPersistence.loadPruned(at: networkActivityLogURL)
            networkActivityLog = pruned.log
            networkActivityLogReadGate.markRead(modifiedAt: pruned.modifiedAt)
        } else if networkActivityLog.pruneExpired() {
            // File unchanged, but the clock crossed the 7-day window while the app
            // sat idle with no new appends. Re-prune and reload atomically so the
            // trimmed file and the gate's mtime stay consistent.
            let pruned = NetworkActivityLogPersistence.loadPruned(at: networkActivityLogURL)
            networkActivityLog = pruned.log
            networkActivityLogReadGate.markRead(modifiedAt: pruned.modifiedAt)
        }
    }

    /// Best-effort: the underlying clear surfaces no failure to the caller, so this always reports
    /// success. Returns `Bool` for a uniform signature with the other clears (see `clearDomainHistory`).
    @discardableResult
    func clearNetworkActivityLog(notifyTunnel: Bool = true) -> Bool {
        guard let networkActivityLogURL else {
            networkActivityLogReadGate.reset()
            networkActivityLog = NetworkActivityLog()
            return true
        }

        NetworkActivityLogPersistence.clear(at: networkActivityLogURL)
        networkActivityLogReadGate.reset()
        networkActivityLog = NetworkActivityLog()
        if notifyTunnel {
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.clearNetworkActivityLogMessage)
            }
        }
        return true
    }

    /// Best-effort: the underlying persist surfaces no failure to the caller, so this always reports
    /// success (see `clearNetworkActivityLog`).
    @discardableResult
    func clearLavaGuardProgress() -> Bool {
        lavaGuardProgress.clearUsageProgress()
        persistLavaGuardProgress()
        // The easter egg rides the same local-log toggle as Lava Guard progress, so a clear of
        // progress also clears the saved Sudoku board — keeping the "off = nothing stored" promise.
        clearSudokuGameState()
        return true
    }

    func setKeepNetworkActivity(_ keepNetworkActivity: Bool, clearActivity: Bool = true) {
        let previous = configuration.keepNetworkActivity
        configuration.keepNetworkActivity = keepNetworkActivity
        do {
            try persistConfigurationOnly()
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            // 🔴 AN OPT-OUT THAT DID NOT PERSIST DID NOT HAPPEN. The in-memory flag used to stay
            // flipped while the on-disk configuration kept its old value — and the on-disk copy is
            // what `HeadlessFocusFilterSwitchEngine` reads from ANOTHER PROCESS. So the clears
            // below ran, the App Intents extension went on reading `keepNetworkActivity == true`,
            // and the next Focus edge wrote the slots straight back: the app believed consent was
            // withdrawn, the writer never heard, and the user saw an error yet the records
            // returned (Codex, PR #625).
            //
            // Rolling back keeps the app, the disk and the other process telling ONE story, and
            // the early return means we do not perform a clear whose premise just failed. The
            // error was already surfaced; the toggle returning to its old position is the honest
            // reflection of a preference that did not save.
            // pinned: ProtectionOnDemandSourceTests.testAFailedOptOutIsNotTreatedAsConsentWithdrawn
            configuration.keepNetworkActivity = previous
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
            return
        }

        if !keepNetworkActivity && clearActivity {
            clearNetworkActivityLog()
            // The Focus diagnostics are Release-persisted, so withdrawing consent has to reach them
            // too. Reached only after the opt-out PERSISTED, so the cross-process writer is reading
            // the same `false` — otherwise this clear is theatre the next Focus edge undoes. Taken
            // under the CONFIGURATION-WRITE lock only. The opt-out's persisted `false` stops future
            // writes, and the purge-on-read handles any legacy record; the timestamped clear-all
            // path additionally hides a pre-clear decision that was already waiting to write.
            Self.withFocusDiagnosticsConsent { _ in
                FocusSwitchDiagnostics.clear(in: LavaSecAppGroup.sharedDefaults)
            }
        }
    }

    func setKeepLavaGuardProgress(_ keepLavaGuardProgress: Bool, clearProgress: Bool = true) {
        configuration.keepLavaGuardProgress = keepLavaGuardProgress
        do {
            try persistConfigurationOnly()
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }

        if keepLavaGuardProgress {
            synchronizeLavaGuardProgress(currentStatus: vpnStatus)
        } else if clearProgress {
            clearLavaGuardProgress()
        }
    }

    /// Generates a fresh Sudoku board for the easter egg, persisting it (when the Lava Guard progress
    /// toggle is on) and returning the new state. Used both for a reshuffle request and for the
    /// "previous puzzle was solved → give a new one" path on entry.
    @discardableResult
    func startFreshSudokuPuzzle(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) -> SudokuGameState {
        let state = SudokuGameState(puzzle: SudokuPuzzle.generate(seed: seed))
        persistSudokuGameState(state)
        return state
    }

    // The account/sign-in feature (beginSignInWithApple/Google, signOutAccount,
    // deleteAccount, and ownership of AccountAuthService) lives in
    // AccountController.swift (Phase D3 account peel) — this hub keeps only the
    // AccountHubBridging conformance in AppViewModel+HubBridges.swift plus the session
    // delegations on the backup bridge.
}
