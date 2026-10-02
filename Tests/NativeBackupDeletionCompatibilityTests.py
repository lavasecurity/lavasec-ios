#!/usr/bin/env python3
"""Execute production backup deletion/upload/setup control flow with isolated I/O.

No app, Keychain, UserDefaults domain, account or network is contacted. The native
methods and canonical durable record/keychain codec are compiled unchanged; only
crypto, account/session transport, and persistence I/O are deterministic doubles.
Run: python3 Tests/NativeBackupDeletionCompatibilityTests.py
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'LavaSecApp/BackupController.swift').read_text()

def method(name, text=source):
    start = text.index('    ' + name)
    if text[:start].endswith('    @discardableResult\n'):
        start -= len('    @discardableResult\n')
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

names = [
    'func enablementPresentation(',
    'private func reloadDeletionFence()', 'private func showDeletionFenceStatus()',
    'private func requireExplicitBackupSetupAllowed()', 'private func completeExplicitBackupEnablement()',
    'func setAutomaticBackupEnabled(', 'func loadAutomaticBackupPreference()',
    'func turnOnEncryptedBackup(', 'func confirmPreparedBackupRestore(', 'private func reconcileRestoredBackupEnvelope(',
    'private func performBackup(feedbackLane:', 'func backUpNow()', 'func clearEncryptedBackup()',
    'func disableEncryptedBackup()', 'private func finishLocalBackupDeletion(',
    'func prepareForAccountDeletion(', 'func finishAccountDeletionMaintenance()',
    'func deleteLocalUnlockSecretsAfterAccountDeletion(', 'private func deleteRemoteEncryptedBackup(',
    'private func uploadEncryptedBackup(', 'private func performEncryptedBackupUpload(',
    'private func recordConfirmedUpload(', 'func uploadPendingEncryptedBackupIfPossible()',
    'func refreshUnavailableBackupStateAfterUnlock()', 'func loadEncryptedBackupState()', 'private func saveLocalEncryptedBackupEnvelope(',
    'private func loadLocalEncryptedBackupEnvelope()',
    'private func synchronizeRemoteBackupAccount()', 'private func invalidateMetadataRequest()',
    'private func confirmRemoteBackupStatus(', 'private func fetchRemoteBackupStatus()',
    'func refreshRemoteBackupStatus()', 'func retrySetupUpload(', 'func isSetupUploadConfirmed(',
    'var encryptedBackupFailureMessage: String?',
    'func scheduleAutomaticBackupAfterConfigurationChange()', 'private func runScheduledAutomaticBackup(',
    'private func refreshLocalEncryptedBackupEnvelope()',
]
methods = '\n'.join(method(name) for name in names)
# Redirect only ordinary preference I/O to an isolated map. All production conditions
# (including stale prefs and the new enabled key) remain unchanged.
methods = methods.replace('UserDefaults.standard', 'TestDefaults.standard')
# Suspend the queued child before its production ownership guard, deterministically
# reproducing an account change between enqueue and actor execution.
methods = methods.replace('let task = Task {', 'let task = Task {\n            await uploadChildEntryHook?()\n', 1)
# Constructor and restore/passkey boundaries are wired in native source and compiled
# in the app gate; these assertions prevent the executable subset becoming orphaned.
assert 'reloadDeletionFence()' in method('init(hub:')
for name in ['func registerBackupPasskey()', 'func validateBackupPasskey()', 'func prepareEncryptedBackupRestore(', 'func confirmPreparedBackupRestore(']:
    body = method(name)
    assert 'try requireExplicitBackupSetupAllowed()' in body, name
assert 'pending.lifecycleGeneration == lifecycleGeneration' in method('func confirmPreparedBackupRestore(')
assert 'pending.accountID == hub.currentBackupAccountID' in method('func confirmPreparedBackupRestore(')
assert 'isBackupMaintenanceInProgress = true' in method('func confirmPreparedBackupRestore(')
assert 'defer { isBackupMaintenanceInProgress = false }' in method('func confirmPreparedBackupRestore(')
assert 'await backup.uploadPendingEncryptedBackupIfPossible()' in (ROOT / 'LavaSecApp/AppViewModel/AppViewModel+HubBridges.swift').read_text()
account_controller = method('func deleteAccount() async -> Bool', (ROOT / 'LavaSecApp/AccountController.swift').read_text())
assert account_controller.index('defer {') < account_controller.index('accountAuthService.deleteAccount(preparing:')
assert 'hub.accountDidFinishDeletion()' in account_controller
assert 'hub.accountWillCompleteDeletion(accountID: deletedAccountID)' in account_controller
keychain_source = (ROOT / 'LavaSecApp/BackupKeychainStore.swift').read_text()
keychain_source = re.sub(r'^import LavaSec\w+\n', '', keychain_source, flags=re.M)
store_source = (ROOT / 'Sources/LavaSecAppServices/BackupEnvelopeStore.swift').read_text().replace('import LavaSecKit\n', '')
model_source = (ROOT / 'Sources/LavaSecAppServices/BackupDeletionIntent.swift').read_text()
feedback_policy_source = (ROOT / 'Sources/LavaSecPresentation/LavaFeedbackPolicy.swift').read_text()
presentation_start = source.index('struct BackupEnablementPresentation:')
presentation_source = source[presentation_start:source.index('@MainActor\nfinal class BackupController:', presentation_start)]
setup_records = source[source.index('struct BackupSetupUploadProgress:'):source.index('/// The narrow hub surface')]

stubs = r'''
import Foundation
import Security
// The app target's String.lavaLocalized extension is out of the extracted-method scope;
// the harness compares behavior, not copy, so identity resolution is enough here.
extension String { var lavaLocalized: String { self } }
extension String { func lavaLocalizedFormat(_ arguments: CVarArg...) -> String { String(format: self, arguments: arguments) } }
// The real pure policy drives a recording sink; only UIKit foreground/hardware are replaced.
@MainActor final class LavaFeedbackCoordinator {
    static let shared = LavaFeedbackCoordinator()
    var policy = LavaFeedbackPolicy()
    var effects: [LavaFeedbackSemantic] = []
    var active = true
    func begin(_ lane: String) -> UUID { policy.begin(lane) }
    func finish(_ lane: String, _ id: UUID, _ semantic: LavaFeedbackSemantic, cancelled: Bool = false) {
        if let effect = policy.finish(lane, id: id, semantic: semantic, active: active,
                                      cancelled: cancelled || Task.isCancelled) { effects.append(effect) }
    }
    func reset() { policy = LavaFeedbackPolicy(); effects = []; active = true }
}
struct BackupAccountSession { let userID: String }
struct BackupRemoteMetadata: Equatable { let userID: String; let uploadedAt: Date? }
enum BackupSyncServiceError: Error { case requestFailed(Int) }
enum EncryptedBackupError: Error { case noBackupAvailable, noSavedDeviceSecret, invalidDeviceUnlock, supersededByConcurrentConfigurationChange }
public enum EncryptedBackupState: Equatable {
    case off, waitingForSignIn(estimatedByteSize: Int), synced(estimatedByteSize: Int, uploadedAt: Date), failed(message: String)
    var isConfigured: Bool { self != .off }
}
struct Payload: Equatable { var value: Int; func hasSameBackupContent(as other: Self) -> Bool { self == other } }
typealias BackupConfigurationPayload = Payload
typealias BackupRestorePlan = Payload
enum ReviewedBackupApplyError: Error { case rejectedBeforeWrite(Error) }
enum BackupRestoreCompletion: Equatable { case complete, filteringNeedsAttention }
struct BackupRestoreReview { let id: UUID; let plan: BackupRestorePlan }
struct PendingBackupRestore {
    let review: BackupRestoreReview
    let replacementToken: Int
    let envelope: ZeroKnowledgeBackupEnvelope
    let newDeviceSecret: String?
    let lifecycleGeneration: UInt64
    let accountID: String?
}
enum BackupConfigurationPayloadError: Error { case unsupportedSchemaVersion }
public struct ZeroKnowledgeBackupEnvelope: Equatable, Codable, Sendable {
    var id = UUID()
    var value = 0
    var keySlots: [Int] { [] }
    var ciphertextByteSize: Int { 1 }
    static func makePasswordless(payload: Payload, deviceSecret: String, serverRecoveryShare: String, recoveryPhrase: String) throws -> Self { Self(value: payload.value) }
    static func makeWithPRF(payload: Payload, deviceSecret: String, serverRecoveryShare: String, recoveryPhrase: String, passkeyPRFOutput: Data, passkeyPRFSalt: Data, passkeyCredentialID: String) throws -> Self { Self(value: payload.value) }
    static func estimatedByteSize(for payload: Payload, keySlotCount: Int) throws -> Int { 1 }
    func decryptWithKeychainSecret(_ secret: String) throws -> Payload { Payload(value: value) }
    func resealingPayload(_ payload: Payload, deviceSecret: String) throws -> Self { Self(value: payload.value) }
}
struct PendingPasskey { let prfOutput: Data; let prfSalt: Data; let credentialID: String }
enum BackupDeviceSecret { static func generate() throws -> String { "new-device-key" } }
enum BackupAssistedRecoverySecret { static func makeServerShare() throws -> String { "fixture-share" } }
enum BackupRecoveryPhrase {
    static func words(from phrase: String) -> [String] { phrase.split(separator: " ").map(String.init) }
    static func phrase(from words: [String]) -> String { words.joined(separator: " ") }
}
@MainActor final class TestDefaults {
    static let standard = TestDefaults()
    var values: [String: Bool] = [:]
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] }
    func bool(forKey key: String) -> Bool { values[key] ?? false }
}
// GenericKeychainStore's I/O is replaced. BackupKeychainStore (including its exact
// service/account keys, strict decode, readback, and completed-only clear) is real.
final class KeychainMemory {
    static let shared = KeychainMemory()
    var values: [String: Data] = [:]
    var refusesRead = false
    var reads = 0
    var refusesIntentSave = false
    var refusesIntentClear = false
    var failsFirstReadAfterClear = false
    var didClearIntent = false
    var refusesSecretSave = false
    var refusesSecretDelete = false
    var failedSecretAccounts: Set<String> = []
    var secretDeleteAttempts: [String] = []
}
struct GenericKeychainStore {
    let service: String
    let unexpectedItemData: BackupKeychainStoreError
    let unhandledStatus: (OSStatus) -> BackupKeychainStoreError
    func loadData(account: String) throws -> Data? {
        KeychainMemory.shared.reads += 1
        if KeychainMemory.shared.refusesRead { throw unexpectedItemData }
        if account == "deletion-intent-v1", KeychainMemory.shared.didClearIntent,
           KeychainMemory.shared.failsFirstReadAfterClear {
            KeychainMemory.shared.failsFirstReadAfterClear = false
            throw unexpectedItemData
        }
        return KeychainMemory.shared.values[service + ":" + account]
    }
    func saveData(_ data: Data, account: String) throws {
        if (account == "deletion-intent-v1" && KeychainMemory.shared.refusesIntentSave)
            || (account == "device-secret" && KeychainMemory.shared.refusesSecretSave) { throw unexpectedItemData }
        KeychainMemory.shared.values[service + ":" + account] = data
    }
    func delete(account: String) throws {
        if account != "deletion-intent-v1" { KeychainMemory.shared.secretDeleteAttempts.append(account) }
        if (account == "deletion-intent-v1" && KeychainMemory.shared.refusesIntentClear)
            || KeychainMemory.shared.failedSecretAccounts.contains(account)
            || (account != "deletion-intent-v1" && KeychainMemory.shared.refusesSecretDelete) { throw unexpectedItemData }
        KeychainMemory.shared.values[service + ":" + account] = nil
        if account == "deletion-intent-v1" { KeychainMemory.shared.didClearIntent = true }
    }
}
final class MemoryStorage: BackupEnvelopeStorage, @unchecked Sendable {
    var dataValues: [String: Data] = [:]
    var dates: [String: Date] = [:]
    var refusesDelete = false
    var refusesConfirmationSave = false
    func data(forKey key: String) -> Data? { dataValues[key] }
    func date(forKey key: String) -> Date? { dates[key] }
    func set(_ value: Data, forKey key: String) {
        if refusesConfirmationSave && key == "lavasec.encryptedBackup.accountDeletionConfirmation" { return }
        dataValues[key] = value
    }
    func set(_ value: Date, forKey key: String) { dates[key] = value }
    func removeObject(forKey key: String) { if !refusesDelete { dataValues[key] = nil; dates[key] = nil } }
}
@MainActor final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class Hub {
    var currentBackupAccountID: String? = "A"
    var libraryOriginatesFromLaunchReseed = false
    var value = 42
    var currentHook: (() async throws -> Void)?
    var refreshHook: (() async throws -> Void)?
    var applyHook: (() async throws -> Void)?
    var applyCompletion = BackupRestoreCompletion.complete
    var isAccountSignedIn: Bool { currentBackupAccountID != nil }
    func currentBackupSession() async throws -> BackupAccountSession? {
        try await currentHook?()
        return currentBackupAccountID.map { BackupAccountSession(userID: $0) }
    }
    func refreshCurrentBackupSession() async throws -> BackupAccountSession? {
        try await refreshHook?()
        return currentBackupAccountID.map { BackupAccountSession(userID: $0) }
    }
    func mirrorAccountAuthState() {}
    func makeBackupConfigurationPayload() -> Payload { Payload(value: value) }
    func isConfigurationReplacementCurrent(_ token: Int) -> Bool { token == 1 }
    func validateBackupRestorePlan(_ plan: BackupRestorePlan, resolverChangeConfirmed: Bool) throws {}
    func applyReviewedBackup(_ plan: BackupRestorePlan, replacementToken: Int, resolverChangeConfirmed: Bool) async throws -> BackupRestoreCompletion {
        value = plan.value
        try await applyHook?()
        return applyCompletion
    }
    func notifyTunnelSnapshotUpdatedAfterRestore() async {}
}
@MainActor final class Sync {
    var deletes: [String] = []
    var uploads: [String] = []
    var uploadedEnvelopes: [ZeroKnowledgeBackupEnvelope] = []
    var restored: [String] = []
    func markRestored(session: BackupAccountSession) async throws { restored.append(session.userID) }
    var deleteHook: (() async throws -> Void)?
    var uploadHook: (() async throws -> Void)?
    var fetchResult: (String) -> BackupRemoteMetadata? = { BackupRemoteMetadata(userID: $0, uploadedAt: nil) }
    func fetchMetadata(session: BackupAccountSession) async throws -> BackupRemoteMetadata? { fetchResult(session.userID) }
    func upload(_ envelope: ZeroKnowledgeBackupEnvelope, session: BackupAccountSession) async throws {
        uploads.append(session.userID); uploadedEnvelopes.append(envelope); try await uploadHook?()
    }
    func deleteRemote(session: BackupAccountSession) async throws {
        deletes.append(session.userID); try await deleteHook?()
    }
}
// ACTUAL_SETUP_RECORDS
@MainActor final class Subject {
    let hub = Hub()
    var backupSyncService: Sync? = Sync()
    let storage: MemoryStorage
    let backupEnvelopeStore: BackupEnvelopeStore
    let backupKeychainStore = BackupKeychainStore()
    init(storage: MemoryStorage = MemoryStorage()) {
        self.storage = storage
        backupEnvelopeStore = BackupEnvelopeStore(storage: storage)
        reloadDeletionFence()
    }
    var hasConfirmedLocalBackup: Bool?
    var isBackupEnabled = false
    var setupUploadProgress: BackupSetupUploadProgress?
    private var pendingSetupUpload: PendingBackupSetupUpload?
    var remoteBackupStatus = "Checking for a backup…"
    var remoteBackupAvailable = false
    var remoteBackupStatusUnavailable = false
    var remoteBackupAccountID: String?
    var hasConfirmedRemoteBackupStatus = false
    var metadataTask: Task<Void, Never>?
    var metadataTaskID: UUID?
    var metadataGeneration: UInt64 = 0
    var deletionIntent: BackupDeletionIntent?
    var deletionFenceReadable = false
    // ACTUAL_FENCE_PREDICATE
    var lifecycleGeneration: UInt64 = 0
    var localOnlyEnvelope: ZeroKnowledgeBackupEnvelope?
    var accountDeletionMaintenanceID: String?
    var accountDeletionConfirmedID: String?
    var confirmedAccountDeletion: BackupDeletionIntent?
    var uploadTask: Task<Void, Never>?
    var uploadFailureSequence: UInt64 = 0
    var automaticBackupTask: Task<Void, Never>?
    var automaticBackupGeneration: UInt64 = 0
    var automaticBackupPreferenceNeedsReload = false
    let automaticBackupDelay: UInt64 = 5 * 60 * 1_000_000_000
    let automaticBackupEnabledDefaultsKeyName = "lavasec.encryptedBackup.automaticBackupEnabled"
    let backupEnabledDefaultsKeyName = "lavasec.encryptedBackup.enabled"
    var isUploadingEncryptedBackup = false
    var isBackingUpNow = false
    var isBackupMaintenanceInProgress = false
    var isAutomaticBackupEnabled = false
    var encryptedBackupState: EncryptedBackupState = .off
    var pendingRestore: PendingBackupRestore?
    var pendingBackupPasskey: PendingPasskey?
    var uploadChildEntryHook: (() async -> Void)?
    private enum RemoteBackupDeletionOutcome { case deleted, unconfirmed }
    func clearPendingBackupPasskey() { pendingBackupPasskey = nil }
    func stopTimer() { automaticBackupTask?.cancel(); automaticBackupTask = nil }
    func seed() throws { try backupEnvelopeStore.saveEnvelope(ZeroKnowledgeBackupEnvelope(value: 1)); try backupKeychainStore.saveDeviceSecret("old-key") }
    func prepareRestoreForTest(newDeviceSecret: String? = "restored-key") -> UUID {
        let review = BackupRestoreReview(id: UUID(), plan: Payload(value: 7))
        pendingRestore = PendingBackupRestore(review: review, replacementToken: 1,
            envelope: ZeroKnowledgeBackupEnvelope(value: 7), newDeviceSecret: newDeviceSecret,
            lifecycleGeneration: lifecycleGeneration, accountID: hub.currentBackupAccountID)
        return review.id
    }
    func resealForTest() { refreshLocalEncryptedBackupEnvelope() }
    func uploadForTest() async -> Bool { await uploadEncryptedBackup(backupEnvelopeStore.loadEnvelope()!, estimatedByteSize: 1) }
'''
predicate = re.search(r'^    private var hasBackupDeletionFence: Bool[^\n]+', source, re.M).group()
stubs = stubs.replace('    // ACTUAL_FENCE_PREDICATE', predicate)
stubs = stubs.replace('// ACTUAL_SETUP_RECORDS', setup_records)

account_change_method = method('func reloadEncryptedBackupStateAfterAccountChange()',
    (ROOT / 'LavaSecApp/AppViewModel/AppViewModel+HubBridges.swift').read_text())
tests = '\n}\n@MainActor final class AccountChangeSubject {\n    let backup = Subject()\n    var account: Hub { backup.hub }\n' + account_change_method + '\n}\n' + r'''
@main struct Tests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: " + message) }
    }
    @MainActor static func reset() {
        LavaFeedbackCoordinator.shared.reset()
        let k = KeychainMemory.shared
        k.values = [:]; k.refusesRead = false; k.refusesIntentSave = false
        k.refusesIntentClear = false; k.failsFirstReadAfterClear = false; k.didClearIntent = false; k.refusesSecretSave = false; k.refusesSecretDelete = false
        TestDefaults.standard.values = [:]
        k.reads = 0
        k.failedSecretAccounts = []; k.secretDeleteAttempts = []
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        fatalError("Controlled suspension did not arrive")
    }
    @MainActor static func main() async throws {
        let key = "com.lavasec.zero-knowledge-backup:deletion-intent-v1"
        let auto = "lavasec.encryptedBackup.automaticBackupEnabled"
        let enabled = "lavasec.encryptedBackup.enabled"
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            await app.backUpNow()
            check(LavaFeedbackCoordinator.shared.effects == [.succeeded], "manual backup announces confirmed upload once")
            await app.backUpNow()
            check(LavaFeedbackCoordinator.shared.effects == [.succeeded, .succeeded], "a separate explicit upload gets its own outcome")
            await app.uploadPendingEncryptedBackupIfPossible()
            check(LavaFeedbackCoordinator.shared.effects.count == 2, "automatic pending upload is silent")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            app.backupSyncService!.uploadHook = { throw BackupSyncServiceError.requestFailed(503) }
            await app.backUpNow()
            check(LavaFeedbackCoordinator.shared.effects == [.failed], "current manual upload failure announces one error")
            app.backupSyncService = nil
            await app.backUpNow()
            check(LavaFeedbackCoordinator.shared.effects == [.failed], "unavailable transport cannot replay previous failure")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState(); let gate = Gate()
            app.backupSyncService!.uploadHook = { await gate.wait() }
            let pending = Task { await app.uploadForTest() }
            await until { gate.continuation != nil }
            await app.backUpNow()
            gate.release(); _ = await pending.value
            check(LavaFeedbackCoordinator.shared.effects.isEmpty, "manual request rejected during automatic upload does not inherit its outcome")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            LavaFeedbackCoordinator.shared.active = false
            await app.backUpNow()
            LavaFeedbackCoordinator.shared.active = true
            check(LavaFeedbackCoordinator.shared.effects.isEmpty, "background completion is consumed without wake replay")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState(); let gate = Gate()
            app.backupSyncService!.uploadHook = { await gate.wait() }
            let manual = Task { await app.backUpNow() }
            await until { gate.continuation != nil }
            manual.cancel(); gate.release(); await manual.value
            check(LavaFeedbackCoordinator.shared.effects.isEmpty, "cancelled explicit task cannot announce eventual transport completion")
        }
        // Execute the production account-change bridge with a scheduled upload.
        reset()
        do {
            let owner = AccountChangeSubject(); let app = owner.backup
            try app.seed(); app.loadEncryptedBackupState(); app.setAutomaticBackupEnabled(true)
            app.scheduleAutomaticBackupAfterConfigurationChange()
            let generation = app.automaticBackupGeneration
            check(app.automaticBackupTask != nil, "automatic upload was scheduled before sign-out")
            app.hub.currentBackupAccountID = nil
            owner.reloadEncryptedBackupStateAfterAccountChange()
            check(!app.isAutomaticBackupEnabled && TestDefaults.standard.values[auto] == false, "sign-out clears in-memory and persisted automatic consent")
            check(app.automaticBackupTask == nil && app.automaticBackupGeneration > generation, "sign-out invalidates the scheduled upload")
            app.hub.currentBackupAccountID = "A"
            app.loadAutomaticBackupPreference()
            check(!app.isAutomaticBackupEnabled, "signing back in does not restore automatic consent")
            check(app.backupEnvelopeStore.loadEnvelope() != nil, "sign-out retains the existing backup")
        }
        // First setup and explicit restoration both clear stale recurring consent.
        for restoring in [false, true] {
            reset()
            let app = Subject(); app.backupSyncService = nil
            app.setAutomaticBackupEnabled(true)
            if restoring {
                try app.seed(); app.loadEncryptedBackupState()
                let id = app.prepareRestoreForTest()
                try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false)
            } else {
                try await app.turnOnEncryptedBackup(recoveryPhrase: "test")
            }
            check(!app.isAutomaticBackupEnabled && TestDefaults.standard.values[auto] == false, "setup or restore defaults automatic uploads to Off")
            app.loadAutomaticBackupPreference()
            check(!app.isAutomaticBackupEnabled, "automatic Off survives preference reload")
        }
        // Overlay an RC13 pending record alongside ciphertext, then sign in and mutate filters.
        reset()
        do {
            let previous = Subject(); try previous.seed()
            try previous.backupKeychainStore.saveDeletionIntent(.init(accountID: "A"))
            TestDefaults.standard.values = [auto: true, enabled: true]
            let app = Subject(storage: previous.storage)
            let ciphertext = app.backupEnvelopeStore.loadEnvelope()
            app.loadAutomaticBackupPreference(); app.loadEncryptedBackupState()
            await app.uploadPendingEncryptedBackupIfPossible(); await app.backUpNow()
            app.scheduleAutomaticBackupAfterConfigurationChange(); app.resealForTest()
            check(app.backupSyncService!.uploads.isEmpty, "overlay and sign-in must not resurrect pending deletion")
            check(app.backupEnvelopeStore.loadEnvelope() == ciphertext, "pending ciphertext cannot be resealed")
            check(TestDefaults.standard.values[auto] == false, "pending deletion persists automatic Off")
            check(app.automaticBackupTask == nil, "pending deletion cannot schedule a timer")
            await app.disableEncryptedBackup()
            check(app.backupSyncService!.deletes == ["A"], "retry deletes original account once")
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "remote and local completion leave tombstone")
            check(app.backupEnvelopeStore.loadEnvelope() == nil, "completed cleanup removes ciphertext")
        }
        // A configured envelope with its unlock key and no Off tombstone refuses setup.
        reset()
        do {
            let prior = Subject(); try prior.seed()
            let priorEnvelope = prior.backupEnvelopeStore.loadEnvelope()
            let app = Subject(storage: prior.storage)
            var refused = false
            do { try await app.turnOnEncryptedBackup(recoveryPhrase: "test phrase") }
            catch EncryptedBackupError.supersededByConcurrentConfigurationChange { refused = true }
            catch { fatalError("unexpected setup error: \(error)") }
            check(refused, "configured envelope refuses explicit setup")
            check(try! app.backupKeychainStore.loadDeviceSecret() == "old-key", "refused setup keeps the existing unlock key")
            check(app.backupEnvelopeStore.loadEnvelope() == priorEnvelope, "refused setup keeps the existing envelope")
        }
        // Completed Off dominates both stale preference keys and a leftover envelope.
        reset()
        do {
            let prior = Subject(); try prior.seed()
            try prior.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .disabled))
            // A completed deletion retains the envelope but removes the unlock key
            // (finishLocalBackupDeletion); model that orphan so explicit setup may replace it.
            try prior.backupKeychainStore.deleteDeviceSecret()
            TestDefaults.standard.values = [auto: true, enabled: true]
            let app = Subject(storage: prior.storage)
            app.loadAutomaticBackupPreference(); app.loadEncryptedBackupState()
            await app.uploadPendingEncryptedBackupIfPossible(); app.scheduleAutomaticBackupAfterConfigurationChange()
            app.setAutomaticBackupEnabled(true)
            check(app.encryptedBackupState == .off, "completed Off wins stale ciphertext")
            check(TestDefaults.standard.values[auto] == false && TestDefaults.standard.values[enabled] == false, "completed Off wins both preferences")
            check(app.backupSyncService!.uploads.isEmpty, "completed Off cannot upload on sign-in")
            KeychainMemory.shared.refusesRead = true
            do { try await app.turnOnEncryptedBackup(recoveryPhrase: "test phrase"); fatalError("initial fence read should fail") } catch {}
            await app.uploadPendingEncryptedBackupIfPossible()
            check(KeychainMemory.shared.values[key] != nil && app.backupSyncService!.uploads.isEmpty, "failed initial fence read retains Off and suppresses upload")
            KeychainMemory.shared.refusesRead = false
            // Failed local-key creation cannot clear Off or replace old ciphertext.
            let priorEnvelope = app.backupEnvelopeStore.loadEnvelope()
            KeychainMemory.shared.refusesSecretSave = true
            do { try await app.turnOnEncryptedBackup(recoveryPhrase: "test phrase"); fatalError("device key write should fail") } catch {}
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "failed key persistence retains Off")
            check(app.backupEnvelopeStore.loadEnvelope() == priorEnvelope, "failed key persistence does not replace ciphertext")
            KeychainMemory.shared.refusesSecretSave = false
            // Failure cannot erase completed Off, even if a local envelope was staged.
            KeychainMemory.shared.refusesIntentClear = true
            do { try await app.turnOnEncryptedBackup(recoveryPhrase: "test phrase"); fatalError("clear should fail") } catch {}
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "failed enablement retains tombstone")
            await app.uploadPendingEncryptedBackupIfPossible()
            check(app.backupSyncService!.uploads.isEmpty, "staged failed enablement cannot upload")
            KeychainMemory.shared.refusesIntentClear = false
            KeychainMemory.shared.failsFirstReadAfterClear = true
            KeychainMemory.shared.refusesIntentSave = true
            // An acknowledged delete is the commit. Even simultaneous inability to
            // read again or compensate must not spuriously fail a successful setup.
            try await app.turnOnEncryptedBackup(recoveryPhrase: "test phrase")
            check(KeychainMemory.shared.values[key] == nil, "acknowledged explicit enablement clears Off without compensation")
            await until { !KeychainMemory.shared.failsFirstReadAfterClear }
            check(app.backupSyncService!.uploads.isEmpty, "later unreadable Keychain still suppresses passive upload")
            await app.uploadPendingEncryptedBackupIfPossible()
            check(app.backupSyncService!.uploads.count == 1, "upload resumes after a successful passive fence read")
            check(try! app.backupKeychainStore.loadDeletionIntent() == nil, "successful explicit enablement alone clears Off")
            check(TestDefaults.standard.values[enabled] == true, "successful explicit setup persists On")
        }
        // Changing accounts cannot repurpose the deletion, including after a 401 refresh.
        reset()
        do {
            let app = Subject(); try app.seed(); try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A"))
            app.hub.currentBackupAccountID = "B"
            await app.disableEncryptedBackup(); await app.uploadPendingEncryptedBackupIfPossible()
            check(app.backupSyncService!.deletes.isEmpty && app.backupSyncService!.uploads.isEmpty, "other account is fenced")
            app.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: "B")
            check(try! app.backupKeychainStore.loadDeviceSecret() == "old-key", "other account deletion cannot remove unlock")
            app.hub.currentBackupAccountID = "A"
            app.backupSyncService!.deleteHook = { throw BackupSyncServiceError.requestFailed(401) }
            app.hub.refreshHook = { app.hub.currentBackupAccountID = "B" }
            await app.disableEncryptedBackup()
            check(app.backupSyncService!.deletes == ["A"], "401 retry never deletes a replacement account")
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .remotePending, "unconfirmed remote deletion stays durable")
        }
        // Malformed, unknown-version/phase and unavailable Keychain records fail closed.
        for bytes in [Data("broken".utf8), Data(#"{"version":2,"accountID":"A","phase":"disabled"}"#.utf8),
                      Data(#"{"version":1,"accountID":"A","phase":"future"}"#.utf8)] {
            reset(); KeychainMemory.shared.values[key] = bytes
            let app = Subject(); try app.seed()
            app.loadAutomaticBackupPreference(); await app.uploadPendingEncryptedBackupIfPossible(); await app.disableEncryptedBackup()
            do { try await app.turnOnEncryptedBackup(recoveryPhrase: "test"); fatalError("malformed intent allowed setup") } catch {}
            check(app.backupSyncService!.uploads.isEmpty && app.backupSyncService!.deletes.isEmpty, "malformed intent suppresses service calls")
            check(KeychainMemory.shared.values[key] == bytes, "malformed intent is never silently discarded")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); KeychainMemory.shared.refusesRead = true
            await app.uploadPendingEncryptedBackupIfPossible(); await app.disableEncryptedBackup()
            check(app.backupSyncService!.uploads.isEmpty && app.backupSyncService!.deletes.isEmpty, "unreadable keychain is not absence")
        }
        // Local cleanup can finish without a session; failure remains durably retryable.
        reset()
        do {
            let app = Subject(); try app.seed(); try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .localCleanupPending))
            app.hub.currentBackupAccountID = "B"; app.storage.refusesDelete = true
            await app.disableEncryptedBackup()
            check(app.backupSyncService!.deletes.isEmpty, "confirmed deletion never needs another account request")
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .localCleanupPending, "failed local persistence remains pending")
            app.storage.refusesDelete = false; await app.disableEncryptedBackup()
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "local retry completes durably")
        }
        // Account deletion cannot cross the server boundary without a durable
        // cleanup fence. A later promotion failure must retain that earlier fence.
        reset()
        do {
            let app = Subject(); try app.seed()
            app.setAutomaticBackupEnabled(true)
            app.scheduleAutomaticBackupAfterConfigurationChange()
            KeychainMemory.shared.refusesIntentSave = true
            var serverBoundaryReached = false
            do {
                try await app.prepareForAccountDeletion(accountID: "A")
                serverBoundaryReached = true
            } catch {}
            await app.finishAccountDeletionMaintenance()
            check(!serverBoundaryReached, "a failed preparation write prevents remote account deletion")
            check(KeychainMemory.shared.secretDeleteAttempts.isEmpty, "failed preparation leaves unlock artifacts intact")
            check(app.automaticBackupTask != nil, "aborted preparation restores the same account's automatic backup")
            app.stopTimer()
        }
        reset()
        do {
            let app = Subject(); try app.seed()
            try await app.prepareForAccountDeletion(accountID: "A")
            let prepared = try app.backupKeychainStore.loadDeletionIntent()
            check(prepared?.version == 3 && prepared?.phase == .remotePending, "retained recovery is fenced before the server request")
            KeychainMemory.shared.refusesIntentSave = true
            app.hub.currentBackupAccountID = nil
            app.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: "A")
            await app.finishAccountDeletionMaintenance()
            let resumed = Subject(storage: app.storage)
            resumed.hub.currentBackupAccountID = "B"
            resumed.loadEncryptedBackupState()
            await resumed.uploadPendingEncryptedBackupIfPossible()
            let retained = try app.backupKeychainStore.loadDeletionIntent()
            check(retained == prepared, "failed post-delete promotion preserves the acknowledged fence")
            check(Set(KeychainMemory.shared.secretDeleteAttempts) == ["recovery-code", "device-secret", "passkey-credential-id"], "an acknowledged preparation still permits all local retirements after promotion failure")
            check(resumed.enablementPresentation().value == nil && resumed.backupSyncService!.uploads.isEmpty, "restart and new sign-in cannot resurrect unfenced backup")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.setAutomaticBackupEnabled(true)
            try await app.prepareForAccountDeletion(accountID: "A")
            KeychainMemory.shared.refusesIntentClear = true
            await app.finishAccountDeletionMaintenance()
            check(app.automaticBackupTask == nil && app.enablementPresentation().value == nil, "failed preflight cancellation keeps backup fenced")
        }
        // Promotion plus partial cleanup failure remains retryable after sign-out,
        // including a new controller. Confirmation cannot authorize another operation.
        for failed in ["device-secret", "final-marker"] {
            reset()
            let app = Subject(); try app.seed()
            try await app.prepareForAccountDeletion(accountID: "A")
            KeychainMemory.shared.refusesIntentSave = true
            KeychainMemory.shared.failedSecretAccounts = failed == "device-secret" ? [failed] : []
            app.hub.currentBackupAccountID = nil
            app.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: "A")
            await app.finishAccountDeletionMaintenance()
            app.loadEncryptedBackupState()
            check(app.enablementPresentation().canRetryDeletion, "confirmed local cleanup survives sign-out and fence reload")
            let resumed = Subject(storage: app.storage)
            resumed.hub.currentBackupAccountID = nil
            resumed.loadEncryptedBackupState()
            check(resumed.enablementPresentation().canRetryDeletion, "matching receipt restores signed-out cleanup after relaunch")
            KeychainMemory.shared.refusesIntentSave = false
            KeychainMemory.shared.failedSecretAccounts = []
            await resumed.disableEncryptedBackup()
            check(try! resumed.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "retry commits Off after primary storage recovers")
            check(resumed.backupSyncService!.deletes.isEmpty && resumed.backupSyncService!.uploads.isEmpty, "signed-out retry performs local cleanup only")
            check(resumed.backupEnvelopeStore.loadEnvelope()?.value == 1, "recovery ciphertext survives local account cleanup")
            for account in ["A", "B"] {
                try resumed.backupKeychainStore.saveDeletionIntent(.init(accountID: account, retainsEnvelopeForRecovery: true))
                let replacement = Subject(storage: app.storage)
                replacement.hub.currentBackupAccountID = nil
                replacement.loadEncryptedBackupState()
                check(!replacement.enablementPresentation().canRetryDeletion, "stale confirmation cannot advance a later operation or another account")
            }
        }
        reset()
        do {
            let app = Subject(); try app.seed()
            try await app.prepareForAccountDeletion(accountID: "A")
            KeychainMemory.shared.refusesIntentSave = true
            app.storage.refusesConfirmationSave = true
            app.hub.currentBackupAccountID = nil
            app.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: "A")
            await app.finishAccountDeletionMaintenance()
            app.loadEncryptedBackupState()
            check(app.enablementPresentation().canRetryDeletion, "live confirmed cleanup remains retryable even if both stores reject promotion")
            let resumed = Subject(storage: app.storage)
            resumed.hub.currentBackupAccountID = nil
            resumed.loadEncryptedBackupState()
            check(!resumed.enablementPresentation().canRetryDeletion, "a launch without persisted confirmation does not invent server success")
            KeychainMemory.shared.refusesIntentSave = false
            await app.disableEncryptedBackup()
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "live confirmation finishes cleanup once Keychain recovers")
        }
        reset()
        do {
            let app = Subject(); try app.seed()
            try await app.prepareForAccountDeletion(accountID: "A")
            KeychainMemory.shared.refusesRead = true
            app.hub.currentBackupAccountID = nil
            app.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: "A")
            await app.finishAccountDeletionMaintenance()
            check(!app.enablementPresentation().canRetryDeletion, "unreadable primary fence still blocks cleanup")
            KeychainMemory.shared.refusesRead = false
            let resumed = Subject(storage: app.storage)
            resumed.hub.currentBackupAccountID = nil
            resumed.loadEncryptedBackupState()
            check(resumed.enablementPresentation().canRetryDeletion, "server confirmation survives a failed primary read and relaunch")
            await resumed.disableEncryptedBackup()
            check(try! resumed.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "unlock permits only the confirmed local cleanup")
            check(resumed.backupSyncService!.deletes.isEmpty, "recovered confirmation never requires deleted-account authentication")
        }
        // Unknown or replaced sessions cannot clear an ambiguous deletion.
        for failure in ["offline", "changed-account"] {
            reset()
            let app = Subject(); try app.seed(); app.setAutomaticBackupEnabled(true)
            try await app.prepareForAccountDeletion(accountID: "A")
            app.hub.refreshHook = {
                if failure == "offline" { throw BackupSyncServiceError.requestFailed(503) }
                app.hub.currentBackupAccountID = "B"
            }
            await app.finishAccountDeletionMaintenance()
            check(app.automaticBackupTask == nil && app.enablementPresentation().value == nil,
                  "an ambiguous deletion cannot resume backup without fresh same-account proof")
            check(!app.isBackupMaintenanceInProgress, "failed reconciliation releases its live lease but retains the durable fence")
        }
        // A failure in any one unlock artifact cannot skip the other deletions.
        // The acknowledged account fence survives a new controller and another
        // sign-in; retry only finishes local cleanup and retains recovery ciphertext.
        for failed in ["recovery-code", "device-secret", "passkey-credential-id"] {
            reset()
            let app = Subject(); try app.seed()
            try app.backupKeychainStore.saveRecoveryCode("phrase")
            try app.backupKeychainStore.savePasskeyCredentialID("credential")
            try await app.prepareForAccountDeletion(accountID: "A")
            app.hub.currentBackupAccountID = nil
            KeychainMemory.shared.failedSecretAccounts = [failed]
            app.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: "A")
            await app.finishAccountDeletionMaintenance()
            check(Set(KeychainMemory.shared.secretDeleteAttempts) == ["recovery-code", "device-secret", "passkey-credential-id"], "every unlock deletion is attempted independently")
            for name in ["recovery-code", "device-secret", "passkey-credential-id"] where name != failed {
                check(KeychainMemory.shared.values["com.lavasec.zero-knowledge-backup:" + name] == nil, "unrelated unlock artifacts are removed")
            }
            let intent = try app.backupKeychainStore.loadDeletionIntent()
            check(intent?.phase == .localCleanupPending && intent?.retainsEnvelopeForRecovery == true, "failed account cleanup is durably fenced")
            let resumed = Subject(storage: app.storage)
            resumed.hub.currentBackupAccountID = "B"
            resumed.loadEncryptedBackupState()
            await resumed.uploadPendingEncryptedBackupIfPossible()
            check(resumed.enablementPresentation().canRetryDeletion && resumed.backupSyncService!.uploads.isEmpty, "relaunch and new sign-in cannot expose a partial cleanup as enabled")
            KeychainMemory.shared.failedSecretAccounts = []
            await resumed.disableEncryptedBackup()
            check(try! resumed.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "retry acknowledges complete key retirement")
            check(resumed.backupEnvelopeStore.loadEnvelope()?.value == 1, "account cleanup preserves encrypted recovery material")
            check(resumed.backupSyncService!.deletes.isEmpty, "account cleanup retry never deletes another account's remote backup")
            check(resumed.enablementPresentation().value == false, "retained ciphertext alone does not enable backup")
        }
        // An in-flight upload must settle before DELETE; its late success cannot record Synced.
        reset()
        do {
            let app = Subject(); try app.seed(); let gate = Gate()
            app.backupSyncService!.uploadHook = { await gate.wait() }
            let upload = Task { await app.uploadPendingEncryptedBackupIfPossible() }
            await until { gate.continuation != nil }
            let deletion = Task { await app.disableEncryptedBackup() }
            await until { app.isBackupMaintenanceInProgress }
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .remotePending, "fence is durable before upload drain")
            check(app.backupSyncService!.deletes.isEmpty, "delete waits for existing upload")
            gate.release(); await upload.value; await deletion.value
            check(app.backupSyncService!.deletes == ["A"] && app.encryptedBackupState == .off, "delete follows upload and wins presentation")
        }
        // A queued upload retains its originating identity before the child starts.
        reset()
        do {
            let app = Subject(); try app.seed(); let gate = Gate()
            app.uploadChildEntryHook = { await gate.wait() }
            let upload = Task { await app.uploadPendingEncryptedBackupIfPossible() }
            await until { gate.continuation != nil }; app.hub.currentBackupAccountID = "B"
            gate.release(); await upload.value
            check(app.backupSyncService!.uploads.isEmpty, "queued upload cannot inherit new account")
        }
        // An unacknowledged fence write cannot authorize destructive requests.
        reset()
        do {
            let app = Subject(); try app.seed(); KeychainMemory.shared.refusesIntentSave = true
            await app.disableEncryptedBackup()
            check(app.backupSyncService!.deletes.isEmpty, "failed intent write prevents deletion")
            check(try! app.backupKeychainStore.loadDeviceSecret() == "old-key", "failed intent preserves restore key")
        }
        // No client is never proof an inherited remotePending backup is gone.
        reset()
        do {
            let app = Subject(); try app.seed(); app.backupSyncService = nil
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A"))
            await app.disableEncryptedBackup()
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .remotePending, "missing service retains inherited pending deletion")
            check(app.backupEnvelopeStore.loadEnvelope() != nil, "missing service cannot orphan remote unlock")
        }
        // Explicitly generated local-only setup has proof there was no upload to delete.
        reset()
        do {
            let app = Subject(); app.backupSyncService = nil; app.hub.currentBackupAccountID = nil
            try await app.turnOnEncryptedBackup(recoveryPhrase: "test phrase")
            app.hub.value += 1; app.scheduleAutomaticBackupAfterConfigurationChange()
            await app.disableEncryptedBackup()
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "proven local-only setup can be disabled offline")
            check(app.backupEnvelopeStore.loadEnvelope() == nil, "local-only disable cleans local envelope")
        }
        // Account deletion preflight owns a lease, and caller's defer can release it
        // even when the account changes during a drained upload.
        reset()
        do {
            let app = Subject(); try app.seed(); let gate = Gate()
            app.backupSyncService!.uploadHook = { await gate.wait() }
            let upload = Task { await app.uploadPendingEncryptedBackupIfPossible() }
            await until { gate.continuation != nil }
            let account = Task {
                do { try await app.prepareForAccountDeletion(accountID: "A"); fatalError("changed preflight should fail") } catch {}
                await app.finishAccountDeletionMaintenance()
            }
            await until { app.isBackupMaintenanceInProgress }; app.hub.currentBackupAccountID = "B"
            gate.release(); await upload.value; await account.value
            check(!app.isBackupMaintenanceInProgress && app.accountDeletionMaintenanceID == nil, "failed account preflight releases lease")
        }
        // A failed server deletion restores the cancelled auto-backup debounce
        // for the same account. An account replacement must not inherit it.
        reset()
        do {
            let app = Subject(); try app.seed()
            app.setAutomaticBackupEnabled(true)
            app.scheduleAutomaticBackupAfterConfigurationChange()
            check(app.automaticBackupTask != nil, "automatic backup scheduled before account deletion")
            try await app.prepareForAccountDeletion(accountID: "A")
            check(app.automaticBackupTask == nil, "account deletion cancels the old debounce")
            await app.finishAccountDeletionMaintenance()
            check(app.automaticBackupTask != nil, "failed same-account deletion restores automatic backup")
            app.stopTimer()
        }
        for replacementAccount: String? in [nil, "B"] {
            reset()
            let app = Subject(); try app.seed()
            app.setAutomaticBackupEnabled(true)
            app.scheduleAutomaticBackupAfterConfigurationChange()
            try await app.prepareForAccountDeletion(accountID: "A")
            app.hub.currentBackupAccountID = replacementAccount
            await app.finishAccountDeletionMaintenance()
            check(app.automaticBackupTask == nil, "completed deletion or account replacement cannot resume the old backup")
        }
        // Restore confirmation uses the real method, with the hub paused at its
        // actual suspension point. A later account cannot clear completed Off.
        reset()
        do {
            let app = Subject(); try app.seed()
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .disabled))
            app.loadEncryptedBackupState()
            let id = app.prepareRestoreForTest(); let gate = Gate()
            app.hub.applyHook = { await gate.wait() }
            let restore = Task {
                do { try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false); fatalError("changed restore should fail") } catch {}
            }
            await until { gate.continuation != nil }
            app.hub.currentBackupAccountID = "B"; gate.release(); await restore.value
            check(try! app.backupKeychainStore.loadDeletionIntent()?.phase == .disabled, "post-apply account change cannot clear Off")
            check(!app.isBackupMaintenanceInProgress, "superseded restore releases maintenance")
            await app.uploadPendingEncryptedBackupIfPossible()
            check(app.backupSyncService!.uploads.isEmpty && app.backupSyncService!.restored.isEmpty, "superseded restore cannot send new-account backup traffic")
        }
        // Account replacement/sign-out during either a successful or failed hub
        // write never persists the review's envelope or its new device key. Exercise
        // the unfenced state too: a pre-existing completed-Off marker hid this bug.
        for replacement: String? in ["B", nil] {
            for applyFails in [false, true] {
                reset()
                let app = Subject(); app.loadEncryptedBackupState()
                let checkpoint = app.backupEnvelopeStore.checkpoint()
                let id = app.prepareRestoreForTest(); let gate = Gate()
                app.hub.applyHook = {
                    await gate.wait()
                    if applyFails { throw BackupSyncServiceError.requestFailed(503) }
                }
                let restore = Task {
                    do { try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false); fatalError("superseded restore should fail") } catch {}
                }
                await until { gate.continuation != nil }
                check(app.backupEnvelopeStore.checkpoint() == checkpoint, "suspended restore keeps previous disk state")
                check(try! app.backupKeychainStore.loadDeviceSecret() == nil, "suspended restore keeps its new device key in memory")
                app.hub.currentBackupAccountID = replacement; gate.release(); await restore.value
                check(app.backupEnvelopeStore.checkpoint() == checkpoint, "superseded or failed apply cannot persist a reviewed envelope")
                check(try! app.backupKeychainStore.loadDeviceSecret() == nil, "superseded or failed apply cannot persist an unlock key")
                check(!app.isBackupMaintenanceInProgress, "superseded or failed apply releases the lease")
                app.isAutomaticBackupEnabled = true
                await app.backUpNow(); app.scheduleAutomaticBackupAfterConfigurationChange()
                check(app.backupSyncService!.uploads.isEmpty && app.automaticBackupTask == nil, "later manual and automatic backup cannot upload the old account's review")
                let relaunched = Subject(storage: app.storage); relaunched.hub.currentBackupAccountID = replacement
                relaunched.loadEncryptedBackupState(); await relaunched.backUpNow()
                check(relaunched.enablementPresentation().value == false && relaunched.backupSyncService!.uploads.isEmpty, "relaunch cannot promote the discarded review")
            }
        }
        // Cancellation after the pair landed cannot discard its working key.
        // A hub return proves durability; cancellation before apply still stops work.
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState()
            let id = app.prepareRestoreForTest(); let gate = Gate()
            app.hub.applyHook = { await gate.wait() }
            let restore = Task { try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false) }
            await until { gate.continuation != nil }
            restore.cancel(); gate.release(); _ = try await restore.value
            check(app.backupEnvelopeStore.loadEnvelope()?.value == 7, "cancellation after durable apply preserves the committed backup")
            check(try! app.backupKeychainStore.loadDeviceSecret() == "restored-key", "cancellation after durable apply preserves the working unlock key")
        }
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState()
            let id = app.prepareRestoreForTest(); var applied = false
            app.hub.applyHook = { applied = true }
            let restore = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do { try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false); fatalError("pre-apply cancellation should stop") } catch {}
            }
            await restore.value
            check(!applied && app.backupEnvelopeStore.loadEnvelope() == nil, "cancellation before apply cannot write configuration or backup")
        }
        // Publication failure is distinct from an unsuccessful configuration write.
        // The saved pair still needs the reviewed key so subsequent edits can reseal.
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState()
            let id = app.prepareRestoreForTest()
            app.hub.applyCompletion = .filteringNeedsAttention
            app.hub.applyHook = { app.hub.value = 77 }
            let result = try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false)
            check(result == .filteringNeedsAttention, "post-pair failure reports filtering attention instead of total restore failure")
            check(app.backupEnvelopeStore.loadEnvelope()?.value == 77, "post-pair failure commits normalized restored content")
            check(try! app.backupKeychainStore.loadDeviceSecret() == "restored-key", "post-pair failure retains the recovered device key")
            app.hub.value = 88; app.scheduleAutomaticBackupAfterConfigurationChange()
            check(app.backupEnvelopeStore.loadEnvelope()?.value == 88, "later edits reseal after post-pair publication failure")
            let relaunched = Subject(storage: app.storage); relaunched.loadEncryptedBackupState()
            await relaunched.backUpNow()
            check(relaunched.backupSyncService!.uploadedEnvelopes.last?.value == 88, "relaunch can back up subsequent edits with the retained key")
        }
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState()
            let id = app.prepareRestoreForTest()
            app.hub.applyCompletion = .filteringNeedsAttention
            app.hub.applyHook = { app.hub.currentBackupAccountID = "B" }
            do { try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false); fatalError("changed account should still stop") } catch {}
            check(app.backupEnvelopeStore.loadEnvelope() == nil, "post-pair failure cannot bypass account ownership")
            check(try! app.backupKeychainStore.loadDeviceSecret() == nil, "new account cannot inherit the review key")
        }
        // Existing ciphertext, unlock key and upload evidence survive account changes
        // without being overwritten by either recovery-key or device-key restores.
        for newKey: String? in ["restored-key", nil] {
            reset()
            let app = Subject(); try app.seed()
            app.backupEnvelopeStore.recordUpload(at: Date(timeIntervalSince1970: 123))
            let checkpoint = app.backupEnvelopeStore.checkpoint()
            let id = app.prepareRestoreForTest(newDeviceSecret: newKey)
            app.hub.applyHook = { app.hub.currentBackupAccountID = "B" }
            do { try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false); fatalError("changed restore should fail") } catch {}
            check(app.backupEnvelopeStore.checkpoint() == checkpoint, "account switch preserves the exact prior envelope and upload receipt")
            check(try! app.backupKeychainStore.loadDeviceSecret() == "old-key", "account switch preserves the prior device key")
        }
        // A later operation owns its changed storage. The old review cannot commit
        // over a replacement envelope/key after the suspended configuration write.
        reset()
        do {
            let app = Subject(); try app.seed()
            let id = app.prepareRestoreForTest()
            app.hub.applyHook = {
                try app.backupEnvelopeStore.saveEnvelope(ZeroKnowledgeBackupEnvelope(value: 88))
                try app.backupKeychainStore.saveDeviceSecret("newer-key")
            }
            do { try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false); fatalError("newer storage should win") } catch {}
            check(app.backupEnvelopeStore.loadEnvelope()?.value == 88, "restore preserves a later operation's envelope")
            check(try! app.backupKeychainStore.loadDeviceSecret() == "newer-key", "restore preserves a later operation's unlock state")
        }
        // Hub reconciliation runs under the same lease before enabling. Automatic
        // resealing/upload stays suppressed; accepted content becomes the local backup.
        reset()
        do {
            let app = Subject(); try app.seed()
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .disabled))
            app.loadEncryptedBackupState()
            let id = app.prepareRestoreForTest()
            app.hub.applyHook = {
                app.hub.value = 77
                app.scheduleAutomaticBackupAfterConfigurationChange()
                check(app.backupEnvelopeStore.loadEnvelope()?.value == 1, "reviewed envelope stays in memory and automatic reseal remains suppressed")
            }
            try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false)
            check(app.backupEnvelopeStore.loadEnvelope()?.value == 77, "explicit restore stores normalized hub content")
            check(try! app.backupKeychainStore.loadDeletionIntent() == nil, "successful reconciled restore can clear completed Off")
            check(!app.isBackupMaintenanceInProgress, "successful restore releases maintenance")
            check(app.backupSyncService!.restored == ["A"], "restore acknowledgement stays on original account")
        }
        // Optional server bookkeeping cannot turn a committed explicit restore into
        // a reported failure if obtaining a session subsequently fails.
        reset()
        do {
            let app = Subject(); try app.seed()
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .disabled))
            app.loadEncryptedBackupState()
            let id = app.prepareRestoreForTest()
            app.hub.currentHook = { throw BackupSyncServiceError.requestFailed(503) }
            try await app.confirmPreparedBackupRestore(id: id, resolverChangeConfirmed: false)
            check(try! app.backupKeychainStore.loadDeletionIntent() == nil, "session bookkeeping failure does not undo explicit restore commit")
            check(app.backupEnvelopeStore.loadEnvelope()?.value == 7, "committed restored content survives bookkeeping failure")
            check(app.backupSyncService!.restored.isEmpty, "unavailable session cannot send restore metadata")
        }
        // A maintenance-only rejection must not invent a pending-deletion status.
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            let state = app.encryptedBackupState
            app.isBackupMaintenanceInProgress = true
            await app.uploadPendingEncryptedBackupIfPossible()
            do { try await app.turnOnEncryptedBackup(recoveryPhrase: "test"); fatalError("maintenance must reject setup") } catch {}
            check(app.encryptedBackupState == state, "maintenance alone does not present deletion-pending copy")
        }
        // The same production presentation owner is exercised after actual
        // controller lifecycle transitions; no JS mirror or storage read in getters.
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState()
            let off = app.enablementPresentation()
            check(off.state == .off && off.value == false && off.canEnable && off.canRestore, "unset backup is an explicit opt-in with restore available")
            check(!off.canDisable && !off.canBackUp && !off.canChangeAutomatic, "unset backup cannot expose enabled operations")
            let setup = app.enablementPresentation(isSetupOrRestorePresented: true)
            check(setup.state == .setup && setup.value == false && !setup.canEnable && !setup.canRestore, "opening setup blocks duplicates without enabling")
            check(app.enablementPresentation().state == .off, "closing setup without commit remains off")
            app.hub.currentBackupAccountID = nil
            let signedOut = app.enablementPresentation()
            check(signedOut.value == false && !signedOut.canEnable && !signedOut.canRestore, "signed-out unset backup has a disabled opt-in")
        }
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState(); app.backupSyncService = nil
            try await app.turnOnEncryptedBackup(recoveryPhrase: "test")
            let on = app.enablementPresentation()
            check(on.state == .on && on.value == true && on.canDisable && on.canBackUp, "successful setup publishes confirmed enabled state")
            check(!app.isAutomaticBackupEnabled && on.canChangeAutomatic, "enabled is independent of automatic upload scheduling")
            let stillPresented = app.enablementPresentation(isSetupOrRestorePresented: true)
            check(stillPresented.state == .setup && stillPresented.value == true && !stillPresented.canRestore, "completed setup retains value until Done without duplicate entry")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            app.backupSyncService!.uploadHook = { throw BackupSyncServiceError.requestFailed(503) }
            await app.backUpNow()
            check({ if case .failed = app.encryptedBackupState { return true }; return false }(), "upload failure actually reached published failure state")
            let failed = app.enablementPresentation()
            check(failed.state == .on && failed.value == true && failed.canBackUp, "upload failure retains confirmed enablement and retry capability")
            app.hub.currentBackupAccountID = nil; app.loadEncryptedBackupState()
            let signedOut = app.enablementPresentation()
            check(signedOut.state == .on && signedOut.value == true, "sign-out never claims configured backup was turned off")
            check(!signedOut.canEnable && !signedOut.canDisable && !signedOut.canBackUp && !signedOut.canRestore && !signedOut.canChangeAutomatic, "signed-out enabled backup disables unavailable operations")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            app.backupSyncService!.deleteHook = { throw BackupSyncServiceError.requestFailed(503) }
            await app.disableEncryptedBackup()
            let pending = app.enablementPresentation()
            check(pending.state == .deletionPending && pending.value == nil && pending.canRetryDeletion, "failed remote deletion stays unresolved despite command return")
            check(!pending.canEnable && !pending.canDisable && !pending.canBackUp && !pending.canRestore && !pending.canChangeAutomatic, "pending deletion blocks conflicting backup actions")
            app.hub.currentBackupAccountID = "B"
            check(!app.enablementPresentation().canRetryDeletion, "remote retry capability is bound to the original account")
            app.hub.currentBackupAccountID = nil
            check(!app.enablementPresentation().canRetryDeletion, "remote retry needs the originating signed-in account")
            app.hub.currentBackupAccountID = "A"; app.backupSyncService!.deleteHook = nil
            await app.disableEncryptedBackup()
            let off = app.enablementPresentation()
            check(off.state == .off && off.value == false && off.canEnable && !off.canRetryDeletion, "completed deletion publishes authoritative Off")
            check(!app.isAutomaticBackupEnabled, "completed deletion also stops automatic backup")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            KeychainMemory.shared.refusesSecretDelete = true
            await app.disableEncryptedBackup()
            app.hub.currentBackupAccountID = nil
            let pending = app.enablementPresentation()
            check(pending.state == .deletionPending && pending.value == nil && pending.canRetryDeletion, "confirmed remote deletion still exposes local-cleanup recovery when signed out")
            KeychainMemory.shared.refusesSecretDelete = false
            await app.disableEncryptedBackup()
            check(app.enablementPresentation().value == false && app.backupSyncService!.deletes == ["A"], "local cleanup finishes without deleting any other account")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            let reads = KeychainMemory.shared.reads
            for _ in 0..<20 { _ = app.enablementPresentation() }
            check(KeychainMemory.shared.reads == reads, "presentation snapshots do not poll Keychain")
            KeychainMemory.shared.refusesRead = true; app.loadEncryptedBackupState()
            let unavailable = app.enablementPresentation()
            check(unavailable.state == .unavailable && unavailable.value == nil, "unreadable evidence does not reuse a stale On or invent Off")
            check(!unavailable.canEnable && !unavailable.canDisable && !unavailable.canBackUp && !unavailable.canRestore && !unavailable.canChangeAutomatic && !unavailable.canRetryDeletion, "unknown deletion state grants no mutation capability")
            KeychainMemory.shared.refusesRead = false
            KeychainMemory.shared.values[key] = Data("malformed".utf8); app.loadEncryptedBackupState()
            check(app.enablementPresentation().state == .unavailable && app.enablementPresentation().value == nil, "corrupt durable record stays unavailable")
        }
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState(); let gate = Gate()
            let review = app.prepareRestoreForTest()
            app.hub.applyHook = { await gate.wait() }
            let restore = Task { try await app.confirmPreparedBackupRestore(id: review, resolverChangeConfirmed: false) }
            await until { gate.continuation != nil }
            let staged = app.enablementPresentation()
            check(staged.state == .busy && staged.value == false, "staged restore is not confirmed enablement")
            check(!staged.canEnable && !staged.canDisable && !staged.canBackUp && !staged.canRestore, "restore lease blocks competing entry")
            app.loadEncryptedBackupState()
            check(app.enablementPresentation().value == false, "account-state reload cannot promote a staged envelope to On")
            gate.release(); _ = try await restore.value
            check(app.enablementPresentation().state == .on && app.enablementPresentation().value == true, "successful restore explicitly enables backup")
        }
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState(); let review = app.prepareRestoreForTest()
            app.hub.applyHook = { throw ReviewedBackupApplyError.rejectedBeforeWrite(EncryptedBackupError.supersededByConcurrentConfigurationChange) }
            do { try await app.confirmPreparedBackupRestore(id: review, resolverChangeConfirmed: false); fatalError("restore should be rejected") } catch {}
            check(app.enablementPresentation().state == .off && app.enablementPresentation().value == false, "rejected restore restores prior Off evidence")
        }
        // Protected-data/foreground recovery is a read-only retry of missing
        // evidence, not a backup operation or a general status reset.
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            KeychainMemory.shared.refusesRead = true; app.loadEncryptedBackupState()
            let data = app.storage.dataValues, dates = app.storage.dates
            let secure = KeychainMemory.shared.values, preferences = TestDefaults.standard.values
            KeychainMemory.shared.refusesRead = false
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.enablementPresentation().value == true && app.enablementPresentation().canRestore, "unlock recovers confirmed backup and available actions without restarting")
            check(app.storage.dataValues == data && app.storage.dates == dates && KeychainMemory.shared.values == secure && TestDefaults.standard.values == preferences, "unlock recovery never rewrites backup, secrets, intent or preferences")
            check(app.backupSyncService!.uploads.isEmpty && app.backupSyncService!.deletes.isEmpty && app.backupSyncService!.restored.isEmpty && app.automaticBackupTask == nil, "unlock recovery performs no service calls or automatic scheduling")
            let reads = KeychainMemory.shared.reads
            app.refreshUnavailableBackupStateAfterUnlock()
            check(KeychainMemory.shared.reads == reads, "normal foreground does not poll readable backup state")
        }
        reset()
        do {
            KeychainMemory.shared.refusesRead = true
            let app = Subject(); app.loadEncryptedBackupState()
            KeychainMemory.shared.refusesRead = false
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.enablementPresentation().value == false && app.enablementPresentation().canEnable, "unlock recovers an unset backup as explicit Off, never enables it")
            check(TestDefaults.standard.values.isEmpty && app.backupEnvelopeStore.loadEnvelope() == nil, "recovering Off creates no preferences or envelope")
        }
        reset()
        do {
            let app = Subject(); try app.seed()
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .disabled))
            TestDefaults.standard.values = [auto: true, enabled: true]
            KeychainMemory.shared.refusesRead = true; app.loadEncryptedBackupState()
            KeychainMemory.shared.refusesRead = false
            let secure = KeychainMemory.shared.values
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.enablementPresentation().value == false && app.enablementPresentation().state == .off, "completed Off still dominates stale ciphertext and preferences after unlock")
            check(KeychainMemory.shared.values == secure && app.backupSyncService!.uploads.isEmpty, "unlock never retires completed Off or revives its server copy")
        }
        reset()
        do {
            let app = Subject(); try app.seed()
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .remotePending))
            app.hub.currentBackupAccountID = "B"
            KeychainMemory.shared.refusesRead = true; app.loadEncryptedBackupState()
            KeychainMemory.shared.refusesRead = false
            let secure = KeychainMemory.shared.values
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.enablementPresentation().state == .deletionPending && app.enablementPresentation().value == nil && !app.enablementPresentation().canRetryDeletion, "unlock recovers a pending deletion without granting a different account retry authority")
            check(KeychainMemory.shared.values == secure && app.backupSyncService!.deletes.isEmpty, "unlock reads but never advances pending deletion")
        }
        reset()
        do {
            let app = Subject(); try app.seed()
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .localCleanupPending))
            app.hub.currentBackupAccountID = nil
            KeychainMemory.shared.refusesRead = true; app.loadEncryptedBackupState()
            KeychainMemory.shared.refusesRead = false
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.encryptedBackupState == .failed(message: "Online backup deleted. Local backup cleanup could not finish. Try turning off backup again."), "signed-out local cleanup gives a local retry instruction, not an account sign-in demand")
            check(app.enablementPresentation().canRetryDeletion && app.backupSyncService!.deletes.isEmpty, "confirmed remote deletion exposes local-only retry without performing it")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.loadEncryptedBackupState()
            app.backupSyncService!.uploadHook = { throw BackupSyncServiceError.requestFailed(503) }
            await app.backUpNow()
            let failure = app.encryptedBackupState, reads = KeychainMemory.shared.reads
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.encryptedBackupState == failure && KeychainMemory.shared.reads == reads, "foreground does not erase a readable upload failure")
            KeychainMemory.shared.values[key] = Data("malformed".utf8); app.loadEncryptedBackupState()
            let secure = KeychainMemory.shared.values
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.enablementPresentation().state == .unavailable && KeychainMemory.shared.values == secure, "a malformed durable record remains unavailable and is never silently discarded")
        }
        reset()
        do {
            let app = Subject(); app.loadEncryptedBackupState(); let gate = Gate()
            let review = app.prepareRestoreForTest()
            app.hub.applyHook = { await gate.wait() }
            let restore = Task { try await app.confirmPreparedBackupRestore(id: review, resolverChangeConfirmed: false) }
            await until { gate.continuation != nil }
            KeychainMemory.shared.refusesRead = true; app.loadEncryptedBackupState()
            KeychainMemory.shared.refusesRead = false
            let state = app.encryptedBackupState, reads = KeychainMemory.shared.reads
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.encryptedBackupState == state && KeychainMemory.shared.reads == reads && app.hasConfirmedLocalBackup == false, "unlock refresh cannot inspect or promote an in-flight staged restore")
            gate.release(); _ = try await restore.value
            check(app.enablementPresentation().value == true, "only the existing successful restore commit promotes staged backup")
        }
        // A locked launch suspends work without revoking the user's durable consent.
        for priorConsent in [true, false] {
            reset()
            let app = Subject(); try app.seed()
            app.setAutomaticBackupEnabled(priorConsent)
            KeychainMemory.shared.refusesRead = true
            app.loadAutomaticBackupPreference()
            check(!app.isAutomaticBackupEnabled, "unavailable Keychain suspends automatic work")
            check(TestDefaults.standard.values[auto] == priorConsent, "locked startup preserves automatic-backup consent")
            KeychainMemory.shared.refusesRead = false
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.isAutomaticBackupEnabled == priorConsent, "unlock restores the saved automatic-backup choice")
            check(TestDefaults.standard.values[auto] == priorConsent, "unlock does not rewrite automatic-backup consent")
            check(app.automaticBackupTask == nil && app.backupSyncService!.uploads.isEmpty,
                  "unlock recovery never schedules or uploads a backup")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.setAutomaticBackupEnabled(true)
            KeychainMemory.shared.refusesRead = true; app.loadAutomaticBackupPreference()
            KeychainMemory.shared.refusesRead = false
            app.loadEncryptedBackupState()
            check(app.deletionFenceReadable && !app.isAutomaticBackupEnabled,
                  "an intervening readable envelope load does not fabricate automatic consent")
            app.refreshUnavailableBackupStateAfterUnlock()
            check(app.isAutomaticBackupEnabled && !app.automaticBackupPreferenceNeedsReload,
                  "unlock still restores consent after another path recovered Keychain evidence")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.setAutomaticBackupEnabled(true)
            KeychainMemory.shared.refusesRead = true; app.loadAutomaticBackupPreference()
            app.setAutomaticBackupEnabled(false)
            KeychainMemory.shared.refusesRead = false; app.refreshUnavailableBackupStateAfterUnlock()
            check(!app.isAutomaticBackupEnabled && TestDefaults.standard.values[auto] == false,
                  "an explicit Off during unavailable storage wins over earlier consent")
        }
        reset()
        do {
            let app = Subject(); try app.seed(); app.setAutomaticBackupEnabled(true)
            try app.backupKeychainStore.saveDeletionIntent(.init(accountID: "A", phase: .disabled))
            KeychainMemory.shared.refusesRead = true; app.loadAutomaticBackupPreference()
            KeychainMemory.shared.refusesRead = false; app.refreshUnavailableBackupStateAfterUnlock()
            check(!app.isAutomaticBackupEnabled && !app.isBackupEnabled,
                  "a recovered completed deletion cannot re-enable automatic backup")
        }
        print("Backup deletion compatibility: \(checks) executable assertions passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lava-backup-deletion-compat-') as directory:
    directory = Path(directory)
    code = directory / 'Compatibility.swift'
    code.write_text(stubs + methods + tests + model_source + presentation_source + keychain_source + store_source + feedback_policy_source)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(directory / 'module-cache'), '-parse-as-library', '-package-name', 'LavaSecPackage', str(code), '-o', str(directory / 'checks')], check=True, cwd=ROOT)
    subprocess.run([str(directory / 'checks')], check=True, cwd=ROOT)
