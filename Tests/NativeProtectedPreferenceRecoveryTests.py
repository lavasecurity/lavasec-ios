#!/usr/bin/env python3
"""Run native preference loaders with locked/unlocked storage doubles.

Production method bodies are compiled unchanged. No real defaults, device, account,
Keychain or network is touched. Run: python3 Tests/NativeProtectedPreferenceRecoveryTests.py
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def method(path, signature, baseline=True):
    source = (ROOT / path).read_text()
    if '--baseline' in sys.argv and baseline:
        source = subprocess.check_output(['git', 'show', 'origin/main:' + path], cwd=ROOT, text=True)
    start = source.index('    ' + signature)
    if source[:start].endswith('    @discardableResult\n'):
        start -= len('    @discardableResult\n')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

customization = '\n'.join(method('LavaSecApp/CustomizationController.swift', name) for name in [
    'func loadCustomizationPreferences()', 'private func persistLavaGuardLook(',
])
policy = (ROOT / 'Sources/LavaSecAppServices/ProtectedPreferenceRecovery.swift').read_text()
app_methods = '\n'.join([
    method('LavaSecApp/AppViewModel/AppViewModel+Persistence.swift', 'func loadProtectedPreferencesIfAvailable()', baseline=False),
    method('LavaSecApp/AppViewModel/AppViewModel+Persistence.swift', 'var canUseProtectedPreferences: Bool', baseline=False),
] + [method('LavaSecApp/AppViewModel/AppViewModel+Persistence.swift', name) for name in [
    'func loadLavaGuardProgress()', 'func persistLavaGuardProgress()',
]] + [method('LavaSecApp/AppViewModel/AppViewModel+Sudoku.swift', name) for name in [
    'func loadSudokuGameState()', 'func persistSudokuGameState(', 'func clearSudokuGameState()',
]])

stubs = r'''
import Foundation
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var isProtectedDataAvailable = false
}
@MainActor final class TestDefaults {
    var values: [String: Any] = [:]
    var writes = 0
    var reads = 0
    func object(forKey key: String) -> Any? {
        reads += 1
        return UIApplication.shared.isProtectedDataAvailable ? values[key] : nil
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func set(_ value: Any, forKey key: String) { writes += 1; values[key] = value }
    func removeObject(forKey key: String) { writes += 1; values.removeValue(forKey: key) }
}
enum GuardianShieldStyle: String { case original, custom }
enum LavaTextSize: String { case systemDefault, large }
struct LavaAppearancePreference: Equatable {
    let value: String
    init(_ value: String) { self.value = value }
}
@MainActor final class AppearancePreferencesService {
    struct Snapshot { let preference: String }
    var refreshes = 0
    func refresh() -> Snapshot { refreshes += 1; return Snapshot(preference: "dark") }
}
struct ProtectionUserDefaultsStorage { let defaults: TestDefaults }
enum LiveActivityPausePreference {
    @MainActor static func minutes(from storage: ProtectionUserDefaultsStorage) -> Int {
        storage.defaults.object(forKey: "pause") as? Int ?? 5
    }
}
enum LavaNotificationCategory: String { case filterChanged, filterCouldNotApply, protectionResumed, connectivity }
enum LavaNotificationPreferences {
    @MainActor static func isEnabled(_ category: LavaNotificationCategory, in defaults: TestDefaults) -> Bool {
        defaults.object(forKey: category.rawValue) as? Bool ?? true
    }
}
@MainActor final class CustomizationSubject {
    let defaults = TestDefaults(), appGroupDefaults = TestDefaults()
    let appearancePreferences = AppearancePreferencesService()
    let textSizeMatchesSystemDefaultsKeyName = "textSystem", textSizeDefaultsKeyName = "textSize"
    let lavaGuardLookDefaultsKey = "look", updatesAppIconWithLavaGuardDefaultsKeyName = "icon"
    let usesLiveActivitiesDefaultsKeyName = "live", usesLavaHapticsDefaultsKey = "haptics"
    var appearancePreference = LavaAppearancePreference("system")
    var textSizeMatchesSystem = true, textSize = LavaTextSize.systemDefault
    var lavaGuardLook = GuardianShieldStyle.original, updatesAppIconWithLavaGuard = true
    var canOfferLiveActivities = true, usesLiveActivities = false, liveActivityPauseMinutes = 5
    var usesLavaHaptics = true, notifiesFilterChanges = true, notifiesFilterCouldNotApply = true
    var notifiesProtectionResumed = true, notifiesConnectivity = true
    var iconSyncs = 0
    private func syncAppIcon(to look: GuardianShieldStyle) { iconSyncs += 1 }
    func seed() {
        defaults.values = ["look": "custom", "textSystem": false, "textSize": "large", "icon": false,
                           "live": true, "haptics": false]
        appGroupDefaults.values = ["look": "custom", "pause": 15, "filterChanged": false,
                                  "filterCouldNotApply": false, "protectionResumed": false, "connectivity": false]
    }
'''
app_stubs = r'''
}
struct LavaGuardProgress: Codable, Equatable { var total = 0 }
struct SudokuGameState: Codable, Equatable { let board: Int }
struct Configuration { var keepLavaGuardProgress = true }
enum NEVPNStatus { case invalid, connected }
@MainActor final class BackupSubject {
    var preferenceLoads = 0, envelopeLoads = 0
    func loadAutomaticBackupPreference() { preferenceLoads += 1 }
    func loadEncryptedBackupState() { envelopeLoads += 1 }
}
@MainActor final class AppSubject {
    var isHeadless = false, sharedStateUnavailableAtLoad = false
    var protectedPreferenceRecovery = ProtectedPreferenceRecovery()
    let defaults = TestDefaults(), customization = CustomizationSubject(), backup = BackupSubject()
    let lavaGuardProgressDefaultsKeyName = "progress", sudokuGameStateDefaultsKeyName = "sudoku"
    var configuration = Configuration(), lavaGuardProgress = LavaGuardProgress()
    var sudokuGameState: SudokuGameState?
    var vpnStatus = NEVPNStatus.connected
    var diagnosticRefreshes = 0, usageRefreshes = 0, activityReconciles = 0
    func refreshLavaGuardProgressFromDiagnostics() { diagnosticRefreshes += 1 }
    func synchronizeLavaGuardProgress(currentStatus: NEVPNStatus) { usageRefreshes += 1 }
    func reconcileLiveActivity() { activityReconciles += 1 }
    func seed() throws {
        defaults.values["progress"] = try JSONEncoder().encode(LavaGuardProgress(total: 42))
        defaults.values["sudoku"] = try JSONEncoder().encode(SudokuGameState(board: 73))
        customization.seed()
    }
'''
tests = r'''
}
@main struct Tests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: " + message) }
    }
    @MainActor static func main() throws {
        let app = AppSubject(); try app.seed()
        let progressData = app.defaults.values["progress"] as? Data
        let boardData = app.defaults.values["sudoku"] as? Data
        app.loadLavaGuardProgress(); app.loadSudokuGameState()
        app.persistLavaGuardProgress(); app.persistSudokuGameState(SudokuGameState(board: 999))
        check(!app.clearSudokuGameState(), "locked clear cannot delete a saved game")
        check(app.defaults.writes == 0 && app.defaults.reads == 0,
              "locked progress/game load and save must defer all preference I/O")
        check(app.defaults.values["progress"] as? Data == progressData
              && app.defaults.values["sudoku"] as? Data == boardData,
              "locked progress/game work preserves both saved records")
        app.loadProtectedPreferencesIfAvailable()
        check(!app.protectedPreferenceRecovery.hasLoaded && app.backup.preferenceLoads == 0,
              "locked startup leaves preference recovery pending")

        let custom = CustomizationSubject(); custom.seed()
        custom.loadCustomizationPreferences()
        check(custom.defaults.writes == 0 && custom.appGroupDefaults.writes == 0,
              "locked customization load must not persist fallback preferences")
        check(custom.defaults.reads == 0 && custom.appGroupDefaults.reads == 0,
              "locked customization load must defer protected reads")
        check(custom.appearancePreferences.refreshes == 0 && custom.iconSyncs == 0,
              "locked customization load must not refresh appearance or change icons")
        UIApplication.shared.isProtectedDataAvailable = true
        app.sharedStateUnavailableAtLoad = true
        app.loadProtectedPreferencesIfAvailable()
        app.configuration.keepLavaGuardProgress = false
        app.loadSudokuGameState()
        check(app.defaults.writes == 0 && app.defaults.reads == 0,
              "unlocked placeholder configuration cannot delete saved progress/game")
        app.configuration.keepLavaGuardProgress = true
        app.sharedStateUnavailableAtLoad = false
        app.loadProtectedPreferencesIfAvailable()
        check(app.protectedPreferenceRecovery.hasLoaded && app.lavaGuardProgress.total == 42
              && app.sudokuGameState?.board == 73, "unlock rehydrates existing progress and game")
        check(app.customization.lavaGuardLook == .custom && app.customization.usesLiveActivities,
              "independent preference recovery runs even with readable control-plane state")
        check(app.backup.preferenceLoads == 1 && app.backup.envelopeLoads == 1,
              "unlock retries both backup startup projections")
        check(app.activityReconciles == 1 && app.usageRefreshes == 1 && app.diagnosticRefreshes == 1,
              "unlock reconciles dependent effects only after the saved preferences load")
        app.lavaGuardProgress = LavaGuardProgress(total: 90)
        app.persistLavaGuardProgress()
        app.persistSudokuGameState(SudokuGameState(board: 91))
        let reads = app.defaults.reads, writes = app.defaults.writes
        app.loadProtectedPreferencesIfAvailable()
        check(app.lavaGuardProgress.total == 90 && app.sudokuGameState?.board == 91,
              "a later foreground does not replay startup data over newer edits")
        check(app.defaults.reads == reads && app.defaults.writes == writes && app.activityReconciles == 1,
              "readable foreground recovery is idempotent")
        check(app.clearSudokuGameState() && app.defaults.values["sudoku"] == nil,
              "an explicit clear still removes the game after recovery")
        let headless = AppSubject(); headless.isHeadless = true; try headless.seed()
        headless.loadProtectedPreferencesIfAvailable()
        headless.persistLavaGuardProgress()
        check(headless.defaults.reads == 0 && headless.defaults.writes == 0
              && headless.backup.preferenceLoads == 0 && headless.customization.defaults.writes == 0,
              "headless refresh never loads or writes protected preferences")
        let disabled = AppSubject(); try disabled.seed(); disabled.configuration.keepLavaGuardProgress = false
        disabled.loadProtectedPreferencesIfAvailable()
        check(disabled.sudokuGameState == nil && disabled.defaults.values["sudoku"] == nil,
              "a real loaded progress-Off preference still removes a stale saved board")
        let unknownVPN = AppSubject(); try unknownVPN.seed(); unknownVPN.vpnStatus = .invalid
        unknownVPN.loadProtectedPreferencesIfAvailable()
        check(unknownVPN.protectedPreferenceRecovery.hasLoaded && unknownVPN.lavaGuardProgress.total == 42,
              "normal startup can restore preferences before VPN status arrives")
        check(unknownVPN.usageRefreshes == 0 && unknownVPN.activityReconciles == 0,
              "placeholder VPN status cannot stop usage or end an existing activity")
        custom.loadCustomizationPreferences()
        check(custom.lavaGuardLook == .custom && custom.textSize == .large && !custom.textSizeMatchesSystem,
              "unlock restores saved Guard and text preferences")
        check(custom.usesLiveActivities && !custom.usesLavaHaptics && custom.liveActivityPauseMinutes == 15,
              "unlock restores Live Activity and haptics choices")
        check(!custom.notifiesFilterChanges && !custom.notifiesFilterCouldNotApply
              && !custom.notifiesProtectionResumed && !custom.notifiesConnectivity,
              "unlock restores every notification preference")
        print("Protected preference recovery: \(checks) executable assertions passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lava-protected-preferences-') as directory:
    directory = Path(directory)
    code = directory / 'Recovery.swift'
    code.write_text(policy + stubs + customization + app_stubs + app_methods + tests)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-module-cache-path', str(directory / 'module-cache'),
                    '-parse-as-library', str(code), '-o', str(directory / 'checks')], check=True, cwd=ROOT)
    subprocess.run([str(directory / 'checks')], check=True, cwd=ROOT)
