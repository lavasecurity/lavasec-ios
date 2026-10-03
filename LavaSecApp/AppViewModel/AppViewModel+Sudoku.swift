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
    // MARK: - Sudoku easter egg persistence

    /// Loads the saved Sudoku board (if any) when the Lava Guard progress toggle is on. While the
    /// toggle is off the saved state is neither loaded nor kept — `clearSudokuGameState()` already
    /// removed the key when the toggle was turned off, so a stray on-disk entry can only exist from
    /// a version that predates this gate; this read-discard keeps it from re-surfacing.
    func loadSudokuGameState() {
        guard UIApplication.shared.isProtectedDataAvailable, !sharedStateUnavailableAtLoad else { return }
        guard configuration.keepLavaGuardProgress else {
            // Also remove the key, not just the in-memory value: a saved board can survive the
            // setKeepLavaGuardProgress(false) clear if the process dies between persisting the config
            // and clearing the key — leaving it on disk would let a later re-enable + relaunch
            // resurface progress that was supposed to be deleted (Codex review on lavasec-ios#512).
            sudokuGameState = nil
            defaults.removeObject(forKey: sudokuGameStateDefaultsKeyName)
            return
        }

        guard let data = defaults.data(forKey: sudokuGameStateDefaultsKeyName),
              let state = try? JSONDecoder().decode(SudokuGameState.self, from: data)
        else {
            sudokuGameState = nil
            return
        }

        sudokuGameState = state
    }

    /// Persists the current Sudoku board so an in-progress game resumes across launches. No-ops while
    /// the Lava Guard progress toggle is off (the easter egg is not saved in that mode), mirroring the
    /// usage-progress accrual gate — and the in-memory `sudokuGameState` is left `nil` too, so leaving
    /// and re-entering the easter egg in a toggle-OFF session does NOT resume the game the user turned
    /// off (the "off = cleared / nothing stored" promise must hold within a session, not just across
    /// relaunches). Best-effort, like `persistLavaGuardProgress`: a JSON failure is swallowed rather
    /// than surfaced — an unsaved easter egg is not a user-visible failure.
    func persistSudokuGameState(_ state: SudokuGameState) {
        guard canUseProtectedPreferences else { return }
        guard configuration.keepLavaGuardProgress else {
            sudokuGameState = nil
            return
        }

        sudokuGameState = state
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        defaults.set(data, forKey: sudokuGameStateDefaultsKeyName)
    }

    /// Clears the saved Sudoku board. Called when the Lava Guard progress toggle is turned off or its
    /// local log is cleared, so the easter egg honors the same "off = not stored" promise as the
    /// other local-log data.
    @discardableResult
    func clearSudokuGameState() -> Bool {
        guard canUseProtectedPreferences else { return false }
        sudokuGameState = nil
        defaults.removeObject(forKey: sudokuGameStateDefaultsKeyName)
        return true
    }

    func loadTemporaryProtectionPause() {
        // ProtectionPauseStore (owned by pauseController) applies session binding
        // and expiry; the published value mirrors the store's authoritative state.
        let pauseUntil = pauseController.currentPauseUntil()
        if temporaryProtectionPauseUntil != pauseUntil {
            temporaryProtectionPauseUntil = pauseUntil
        }

        if pauseUntil == nil {
            pauseController.onPauseCleared()
        }
    }

    func beginFreshProtectionVPNSession() {
        _ = try? protectionSessionStore.beginFreshSession()
        clearTemporaryProtectionPause()
    }

    func endProtectionVPNSession() {
        _ = try? protectionSessionStore.clearActiveSessionID()
        clearTemporaryProtectionPause()
    }

    func scheduleTemporaryProtectionResume(retryDelay: TimeInterval? = nil) {
        pauseController.scheduleResume(until: temporaryProtectionPauseUntil, retryDelay: retryDelay) { [weak self] in
            await self?.resumeTemporaryProtectionIfExpired()
        }
    }
}
