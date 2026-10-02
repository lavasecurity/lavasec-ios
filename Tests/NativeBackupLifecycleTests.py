#!/usr/bin/env python3
"""Run the production backup lifecycle methods with controlled suspension points.

This portable harness extracts native controller methods and supplies in-memory
hub/store doubles. Scheduling replaces only its sleep and wall-time APIs with
independent controlled clocks. It verifies ordering without UIKit, credentials or
network access; the integrated app build still verifies native wiring.
Run: python3 Tests/NativeBackupLifecycleTests.py
"""
from pathlib import Path
import argparse
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline-ref', help='Read BackupController from this explicit git ref for reproducible RED checks')
parser.add_argument('--baseline-upload-ref', help='Replace only uploadEncryptedBackup with this explicit git ref to isolate child-handoff RED checks')
args = parser.parse_args()
source = (subprocess.run(['git', 'show', f'{args.baseline_ref}:LavaSecApp/BackupController.swift'], cwd=root,
                         check=True, capture_output=True, text=True).stdout if args.baseline_ref else
          (root / 'LavaSecApp/BackupController.swift').read_text())
upload_source = (subprocess.run(['git', 'show', f'{args.baseline_upload_ref}:LavaSecApp/BackupController.swift'], cwd=root,
                               check=True, capture_output=True, text=True).stdout if args.baseline_upload_ref else source)

def method(name, method_source=source):
    source = method_source
    start = source.index('    ' + name)
    if source[:start].endswith('    @discardableResult\n'):
        start -= len('    @discardableResult\n')
    opening = source.index('{', start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

methods = '\n'.join(method(name, upload_source if name == 'private func uploadEncryptedBackup(' else source)
                    .replace('private func completeExplicitBackupEnablement()', 'func completeExplicitBackupEnablement()')
                    for name in [
    'func refreshRemoteBackupStatus()', 'func clearEncryptedBackup()',
    'func disableEncryptedBackup()', 'private func deleteRemoteEncryptedBackup(',
    'private func reloadDeletionFence()', 'private func showDeletionFenceStatus()',
    'func loadAutomaticBackupPreference()', 'func loadEncryptedBackupState()',
    'private func completeExplicitBackupEnablement()', 'private func requireExplicitBackupSetupAllowed()',
    'private func uploadEncryptedBackup(', 'func setAutomaticBackupEnabled(',
    'private func finishLocalBackupDeletion(', 'func prepareForAccountDeletion(',
    'func finishAccountDeletionMaintenance()', 'func deleteLocalUnlockSecretsAfterAccountDeletion(',
    'func turnOnEncryptedBackup(',
    'var encryptedBackupFailureMessage: String?', 'var backupStatusSubtitle: String',
    'private func synchronizeRemoteBackupAccount()', 'private func invalidateMetadataRequest()',
    'private func confirmRemoteBackupStatus(', 'private func fetchRemoteBackupStatus()',
    'func retrySetupUpload(', 'func isSetupUploadConfirmed(',
    'private func performEncryptedBackupUpload(', 'private func recordConfirmedUpload(',
    'func backUpNow()', 'private func performBackup(',
])
# Suspend only at the upload child's entry, modelling an already queued actor job
# that runs after account/lifecycle state changes. All production guards stay intact.
upload_method = method('private func uploadEncryptedBackup(', upload_source)
assert upload_method.count('let task = Task {') == 1
methods = methods.replace(upload_method, upload_method.replace('let task = Task {', 'let task = Task {\n            await uploadChildEntryHook?()\n', 1))
# The scheduling control flow is production code. Substitute only its clock APIs:
# a manually advanced monotonic sleeper and an independently adjustable wall clock.
# This reproduces clock rollback without changing machine time or waiting five minutes.
scheduling_methods = '\n'.join(method(name) for name in [
    'func scheduleAutomaticBackupAfterConfigurationChange()',
    'private func runScheduledAutomaticBackup(',
]).replace('Task.sleep(nanoseconds: automaticBackupDelay)', 'ControlledTime.sleep(nanoseconds: automaticBackupDelay)')
scheduling_methods = scheduling_methods.replace('Date()', 'ControlledTime.wallNow')
methods += '\n' + scheduling_methods
schedule_field = re.search(r'^    private var (?:automaticSchedule|automaticBackupGeneration)[^\n]+', source, re.M).group()
delay_field = re.search(r'^    private let automaticBackupDelay[^\n]+', source, re.M).group()
store_source = (root / 'Sources/LavaSecAppServices/BackupEnvelopeStore.swift').read_text()
store_marker_methods = '\n'.join(method(name, store_source).replace('public func', 'func').replace('package func', 'func') for name in [
    'public func clearUploadMarker()', 'public func currentState()',
    'public func recordUploadIfCurrent(', 'package func recordUpload(', 'package func lastUploadedAt()',
])
stubs = r'''
import Foundation
struct BackupAccountSession { let userID: String; var accessToken: String { userID } }
struct BackupRemoteMetadata { let userID: String; let uploadedAt: Date? }
enum BackupSyncServiceError: Error { case requestFailed(Int) }
enum EncryptedBackupError: Error { case noBackupAvailable, invalidDeviceUnlock, supersededByConcurrentConfigurationChange }
@MainActor final class LavaFeedbackCoordinator {
    enum Outcome { case succeeded, failed }
    static let shared = LavaFeedbackCoordinator()
    func begin(_ lane: String) -> UUID { UUID() }
    func finish(_ lane: String, _ id: UUID, _ outcome: Outcome, cancelled: Bool = false) {}
}
enum State { case synced(estimatedByteSize: Int, uploadedAt: Date); case configured; case off; case waitingForSignIn(estimatedByteSize: Int); case failed(message: String); var isConfigured: Bool { if case .off = self { return false }; return true } }
typealias EncryptedBackupState = State
// Crypto generation is a deterministic double; these checks exercise the actual
// controller's guard and persistence path, not encryption correctness.
struct ZeroKnowledgeBackupEnvelope: Equatable {
    var id = UUID()
    var keySlots: [Int] { [] }
    static func makePasswordless(payload: Int, deviceSecret: String, serverRecoveryShare: String, recoveryPhrase: String) throws -> Self { Self() }
    static func makeWithPRF(payload: Int, deviceSecret: String, serverRecoveryShare: String, recoveryPhrase: String, passkeyPRFOutput: Data, passkeyPRFSalt: Data, passkeyCredentialID: String) throws -> Self { Self() }
    static func estimatedByteSize(for payload: Int, keySlotCount: Int) throws -> Int { 1 }
}
struct PendingPasskey { let prfOutput: Data; let prfSalt: Data; let credentialID: String }
enum BackupDeviceSecret { static func generate() throws -> String { "new-device-key" } }
enum BackupAssistedRecoverySecret { static func makeServerShare() throws -> String { "fixture-share" } }
enum BackupRecoveryPhrase {
    static func words(from phrase: String) -> [String] { phrase.split(separator: " ").map(String.init) }
    static func phrase(from words: [String]) -> String { words.joined(separator: " ") }
}
enum DeviceSecretReadError: Error { case unavailable }
extension String { var lavaLocalized: String { self }; func lavaLocalizedFormat(_ values: CVarArg...) -> String { String(format: self, arguments: values) } }
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Bool] = [:]
    func set(_ value: Bool, forKey: String) { values[forKey] = value }
    func bool(forKey: String) -> Bool { values[forKey] ?? false }
    func object(forKey: String) -> Any? { values[forKey] }
}
@MainActor final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class Hub {
    var currentBackupAccountID: String? = "A"
    var libraryOriginatesFromLaunchReseed = false
    var isAccountSignedIn: Bool { currentBackupAccountID != nil }
    func currentBackupSession() async throws -> BackupAccountSession? { currentBackupAccountID.map { BackupAccountSession(userID: $0) } }
    func refreshCurrentBackupSession() async throws -> BackupAccountSession? { try await currentBackupSession() }
    func mirrorAccountAuthState() {}
    func makeBackupConfigurationPayload() -> Int { 0 }
}
@MainActor final class Sync {
    var deletes: [String] = []
    var fetches = 0
    var deleteHook: (() async throws -> Void)?
    var fetchHook: (() async throws -> Void)?
    var fetchResult: (String) -> BackupRemoteMetadata? = { BackupRemoteMetadata(userID: $0, uploadedAt: nil) }
    var uploads: [String] = []
    var uploadHook: (() async throws -> Void)?
    func upload(_ envelope: ZeroKnowledgeBackupEnvelope, session: BackupAccountSession) async throws {
        uploads.append(session.userID); try await uploadHook?()
    }
    func deleteRemote(session: BackupAccountSession) async throws { deletes.append(session.userID); try await deleteHook?() }
    func fetchMetadata(session: BackupAccountSession) async throws -> BackupRemoteMetadata? {
        fetches += 1; let result = fetchResult(session.userID); try await fetchHook?(); return result
    }
}
@MainActor final class Keychain {
    var deletes = 0
    var intentData: Data?
    var refusesSave = false
    var refusesRead = false
    var refusesCompletedDeletionClear = false
    var failsAfterSave = false
    var deviceSecret: String? = "original-device-key"
    var deviceSecretReads = 0
    var refusesDeviceSecretRead = false
    var refusesDeviceSecretSave = false
    func loadDeviceSecret() throws -> String? {
        deviceSecretReads += 1
        if refusesDeviceSecretRead { throw DeviceSecretReadError.unavailable }
        return deviceSecret
    }
    func saveDeviceSecret(_ secret: String) throws {
        if refusesDeviceSecretSave { throw DeviceSecretReadError.unavailable }
        deviceSecret = secret
    }
    func savePasskeyCredentialID(_ id: String) throws {}
    func loadDeletionIntent() throws -> BackupDeletionIntent? {
        if refusesRead { throw EncryptedBackupError.invalidDeviceUnlock }
        return try intentData.map(BackupDeletionIntent.decode)
    }
    func saveDeletionIntent(_ value: BackupDeletionIntent) throws {
        if refusesSave { throw EncryptedBackupError.invalidDeviceUnlock }
        intentData = try JSONEncoder().encode(value)
        if failsAfterSave { throw EncryptedBackupError.invalidDeviceUnlock }
    }
    func clearCompletedDeletionIntent() throws {
        if refusesCompletedDeletionClear { throw EncryptedBackupError.invalidDeviceUnlock }
        intentData = nil
    }
    func cancelAccountDeletionPreparation(_ intent: BackupDeletionIntent) throws { intentData = nil }
    func deleteRecoveryCode() throws { deletes += 1 }
    func deleteDeviceSecret() throws { deletes += 1; deviceSecret = nil }
    func deletePasskeyCredentialID() throws { deletes += 1 }
}
@MainActor final class UploadMarkerStorage {
    var dates: [String: Date] = [:]
    func date(forKey key: String) -> Date? { dates[key] }
    func set(_ value: Date, forKey key: String) { dates[key] = value }
    func removeObject(forKey key: String) { dates[key] = nil }
}
@MainActor final class Envelope {
    private enum Keys { static let lastUploadedAt = "test-upload-marker" }
    private let storage = UploadMarkerStorage()
    var exists = true
    var envelope = ZeroKnowledgeBackupEnvelope()
    var refusesDelete = false
    var saveCount = 0
    var markersAtSave: [Date?] = []
    private var deletionConfirmation: BackupDeletionIntent?
    func loadEnvelope() -> ZeroKnowledgeBackupEnvelope? { exists ? envelope : nil }
    func saveEnvelope(_ value: ZeroKnowledgeBackupEnvelope) throws {
        markersAtSave.append(lastUploadedAt())
        saveCount += 1
        envelope = value; exists = true
    }
    func accountDeletionConfirmation(for intent: BackupDeletionIntent) -> BackupDeletionIntent? { deletionConfirmation }
    func saveAccountDeletionConfirmation(_ intent: BackupDeletionIntent) { deletionConfirmation = intent }
    // ACTUAL_STORE_MARKER_METHODS
    func estimatedByteSize(for envelope: ZeroKnowledgeBackupEnvelope) -> Int { 1 }
    func deleteEnvelope() -> Bool { if refusesDelete { return false }; exists = false; clearUploadMarker(); return true }
}
@MainActor enum ControlledTime {
    static var monotonic: UInt64 = 0
    static var wallNow = Date(timeIntervalSince1970: 100_000)
    static var pending: [(deadline: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    static func reset() {
        precondition(pending.isEmpty)
        monotonic = 0; wallNow = Date(timeIntervalSince1970: 100_000)
    }
    static func sleep(nanoseconds: UInt64) async throws {
        await withCheckedContinuation { pending.append((monotonic + nanoseconds, $0)) }
    }
    static func advance(by nanoseconds: UInt64) {
        monotonic += nanoseconds
        let due = pending.filter { $0.deadline <= monotonic }
        pending.removeAll { $0.deadline <= monotonic }
        for item in due { item.continuation.resume() }
    }
}
@MainActor final class Subject {
    let hub = Hub()
    var backupSyncService: Sync? = Sync()
    let backupEnvelopeStore: Envelope
    let backupKeychainStore: Keychain
    init(keychain: Keychain, envelope: Envelope) {
        backupKeychainStore = keychain; backupEnvelopeStore = envelope
        reloadDeletionFence()
        isBackupEnabled = envelope.exists && deletionIntent?.phase != .disabled
    }
    convenience init() { self.init(keychain: Keychain(), envelope: Envelope()) }
    var deletionIntent: BackupDeletionIntent?
    var accountDeletionMaintenanceID: String?
    var deletionFenceReadable = false
    var hasBackupDeletionFence: Bool { !deletionFenceReadable || deletionIntent?.blocksBackupWork == true }
    var uploads: Int { backupSyncService?.uploads.count ?? 0 }
    var isUploadingEncryptedBackup = false
    var isBackingUpNow = false
    var uploadChildEntryHook: (() async -> Void)?
    var localReseals = 0
    func refreshLocalEncryptedBackupEnvelope() { localReseals += 1 }
    func reloadForTest() { reloadDeletionFence() }
    func explicitlyEnableForTest() {
        do {
            try requireExplicitBackupSetupAllowed()
            try completeExplicitBackupEnablement()
            loadEncryptedBackupState()
        } catch { /* The extracted production methods publish their own failure state. */ }
    }
    func attemptUpload() async { await uploadEncryptedBackup(ZeroKnowledgeBackupEnvelope(), estimatedByteSize: 1) }
    func uploadForTest() async -> Bool { await uploadEncryptedBackup(backupEnvelopeStore.envelope, estimatedByteSize: 1) }
    var isBackupMaintenanceInProgress = false
    var isBackupEnabled = true
    var hasConfirmedLocalBackup: Bool? = true
    var localOnlyEnvelope: ZeroKnowledgeBackupEnvelope?
    var confirmedAccountDeletion: BackupDeletionIntent?
    var accountDeletionConfirmedID: String?
    var uploadFailureSequence: UInt64 = 0
    var isAutomaticBackupEnabled = true
    var lifecycleGeneration: UInt64 = 0
    var setupUploadProgress: BackupSetupUploadProgress?
    private var pendingSetupUpload: PendingBackupSetupUpload?
    var remoteBackupAccountID: String?
    var hasConfirmedRemoteBackupStatus = false
    var metadataTask: Task<Void, Never>?
    var metadataTaskID: UUID?
    var metadataGeneration: UInt64 = 0
    var automaticBackupTask: Task<Void, Never>?
    var automaticBackupPreferenceNeedsReload = false
    var uploadTask: Task<Void, Never>?
    // ACTUAL_AUTOMATIC_SCHEDULE_FIELDS
    var remoteBackupStatus = "Backup available"
    var remoteBackupAvailable = true
    var remoteBackupStatusUnavailable = false
    var encryptedBackupState = State.configured
    var pendingRestore: String?
    var pendingBackupPasskey: PendingPasskey?
    var envelopeWrites = 0
    var markersAtEnvelopeWrite: [Date?] = []
    func loadLocalEncryptedBackupEnvelope() -> ZeroKnowledgeBackupEnvelope? { backupEnvelopeStore.loadEnvelope() }
    func saveLocalEncryptedBackupEnvelope(_ envelope: ZeroKnowledgeBackupEnvelope) throws {
        markersAtEnvelopeWrite.append(backupEnvelopeStore.lastUploadedAt())
        envelopeWrites += 1; backupEnvelopeStore.exists = true; backupEnvelopeStore.envelope = envelope
    }
    let backupEnabledDefaultsKeyName = "test-only"
    let automaticBackupEnabledDefaultsKeyName = "automatic-test-only"
    private enum RemoteBackupDeletionOutcome { case deleted, unconfirmed }
    func clearPendingBackupPasskey() { pendingBackupPasskey = nil }
'''
account_methods = method('func deleteAccount(preparing:', (root / 'LavaSecApp/AccountAuthService.swift').read_text())
controller_methods = method('func deleteAccount() async -> Bool', (root / 'LavaSecApp/AccountController.swift').read_text())
bridge_source = (root / 'LavaSecApp/AppViewModel/AppViewModel+HubBridges.swift').read_text()
bridge_methods = '\n'.join(method(name, bridge_source) for name in [
    'func accountWillBeginDeletion(', 'func accountWillCompleteDeletion(', 'func accountDidFinishDeletion()',
])
account_stubs = r'''
}
enum AccountAuthError: Error { case cancelled }
struct Connections {
    let accountID: String?
    init(accountID: String? = nil) { self.accountID = accountID }
    func contains(userID: String) -> Bool { accountID == userID }
    var isEmpty: Bool { accountID == nil }
}
typealias AccountAuthConnections = Connections
struct AuthState {
    var accountID: String?
    var connections: Connections { Connections(accountID: accountID) }
    var signingInProvider: String? { nil }
    static func signingIn(connections: Connections, provider: String) -> AuthState { AuthState(accountID: connections.accountID) }
    static func signedIn(connections: Connections) -> AuthState { AuthState(accountID: connections.accountID) }
}
@MainActor final class AccountRPC {
    var deletedIDs: [String] = []
    var hook: (() async throws -> Void)?
}
@MainActor struct AccountDeletionClient {
    let urlSession: AccountRPC
    func deleteAccount(accessToken: String) async throws {
        urlSession.deletedIDs.append(accessToken)
        try await urlSession.hook?()
    }
}
@MainActor final class SessionStore { func deleteAllSessions() throws {} }
@MainActor final class AuthService {
    var state = AuthState(accountID: "A")
    let urlSession = AccountRPC()
    var signOuts = 0
    var sessionGeneration: UInt64 = 0
    let sessionStore = SessionStore()
    func signOut() { sessionGeneration &+= 1; signOuts += 1; state.accountID = nil }
    func currentBackupSession() async throws -> BackupAccountSession? {
        state.accountID.map { BackupAccountSession(userID: $0) }
    }
'''
bridge_stubs = r'''
}
@MainActor final class AccountHub {
    let backup: Subject
    init(backup: Subject) { self.backup = backup }
    var reloads = 0
    func reloadEncryptedBackupStateAfterAccountChange() { reloads += 1 }
'''
controller_stubs = r'''
}
enum ProtectionHapticFeedback {
    enum Cue { case actionSucceeded, actionFailed }
    static func play(_ cue: Cue) {}
}
@MainActor final class AccountSubject {
    let hub: AccountHub
    let accountAuthService = AuthService()
    var accountAuthState = AuthState(accountID: "A")
    var accountAuthMessage: String?
    var accountAuthMessageIsError = false
    var isAccountDeletionInProgress = false
    init(backup: Subject) { hub = AccountHub(backup: backup) }
'''
tests = r'''
}
@main struct Tests {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        fatalError("Controlled suspension point was not reached")
    }
    @MainActor static func main() async {
        for clearOnly in [false, true] {
            let subject = Subject(), gate = Gate()
            subject.uploadTask = Task { await gate.wait() }
            await until { gate.continuation != nil }
            let operation = Task { if clearOnly { await subject.clearEncryptedBackup() } else { await subject.disableEncryptedBackup() } }
            await until { subject.isBackupMaintenanceInProgress }
            subject.hub.currentBackupAccountID = "B"
            gate.release(); await operation.value
            precondition(subject.backupSyncService!.deletes.isEmpty, "must not delete B after waiting for A upload")
            precondition(subject.backupEnvelopeStore.exists && subject.backupKeychainStore.deletes == 0)
            precondition(subject.isBackupEnabled)
        }
        do {
            let subject = Subject()
            subject.hub.currentBackupAccountID = nil
            await subject.disableEncryptedBackup()
            subject.hub.currentBackupAccountID = "B"
            precondition(subject.backupSyncService!.deletes.isEmpty, "signed-out request must not start a deletion")
            precondition(subject.backupKeychainStore.intentData == nil)
            precondition(subject.backupEnvelopeStore.exists && subject.backupKeychainStore.deletes == 0)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.backupSyncService!.deleteHook = { await gate.wait() }
            let operation = Task { await subject.disableEncryptedBackup() }
            await until { gate.continuation != nil }
            subject.hub.currentBackupAccountID = "B"
            gate.release(); await operation.value
            precondition(subject.backupSyncService!.deletes == ["A"])
            precondition(subject.backupEnvelopeStore.exists && subject.backupKeychainStore.deletes == 0)
        }
        do {
            let subject = Subject()
            subject.backupSyncService!.deleteHook = { subject.hub.currentBackupAccountID = "B"; throw BackupSyncServiceError.requestFailed(401) }
            await subject.disableEncryptedBackup()
            precondition(subject.backupSyncService!.deletes == ["A"], "401 must not retry with B")
            precondition(subject.backupEnvelopeStore.exists && subject.backupKeychainStore.deletes == 0)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.backupSyncService!.fetchHook = { await gate.wait() }
            let metadata = Task { await subject.refreshRemoteBackupStatus() }
            await until { gate.continuation != nil }
            await subject.disableEncryptedBackup()
            precondition(!subject.isBackupEnabled)
            gate.release(); await metadata.value
            precondition(!subject.isBackupEnabled && !subject.remoteBackupAvailable, "old metadata must not revive Off")
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.backupSyncService!.deleteHook = { await gate.wait() }
            let operation = Task { await subject.disableEncryptedBackup() }
            await until { gate.continuation != nil }
            await subject.refreshRemoteBackupStatus()
            precondition(subject.backupSyncService!.fetches == 0, "maintenance must suppress new metadata reads")
            gate.release(); await operation.value
            precondition(!subject.isBackupEnabled && !subject.isAutomaticBackupEnabled)
            precondition(!subject.backupEnvelopeStore.exists && subject.backupKeychainStore.deletes == 3)
        }
        do {
            let subject = Subject()
            subject.backupEnvelopeStore.refusesDelete = true
            await subject.disableEncryptedBackup()
            precondition(subject.isBackupEnabled && subject.deletionIntent?.phase == .localCleanupPending)
            guard case .failed = subject.encryptedBackupState else { fatalError("partial cleanup must stay retryable") }
        }
        do {
            let subject = Subject()
            subject.backupKeychainStore.refusesSave = true
            await subject.disableEncryptedBackup()
            precondition(subject.backupSyncService!.deletes.isEmpty, "failed durable fence must prevent the network delete")
            precondition(subject.backupKeychainStore.deletes == 0 && subject.backupEnvelopeStore.exists)
        }
        do {
            let original = Subject()
            original.backupSyncService!.deleteHook = { throw BackupSyncServiceError.requestFailed(503) }
            await original.disableEncryptedBackup()
            precondition(original.deletionIntent?.phase == .remotePending)
            let restarted = Subject(keychain: original.backupKeychainStore, envelope: original.backupEnvelopeStore)
            restarted.loadAutomaticBackupPreference()
            restarted.hub.currentBackupAccountID = "B"
            await restarted.attemptUpload()
            await restarted.refreshRemoteBackupStatus()
            precondition(restarted.uploads == 0 && restarted.backupSyncService!.deletes.isEmpty)
            precondition(restarted.backupSyncService!.fetches == 0, "pending deletion must not re-enable from metadata")
            restarted.hub.currentBackupAccountID = "A"
            await restarted.refreshRemoteBackupStatus()
            precondition(restarted.backupSyncService!.deletes.isEmpty, "metadata refresh must not retry deletion")
            await restarted.disableEncryptedBackup()
            precondition(restarted.backupSyncService!.deletes == ["A"])
            precondition(!restarted.isBackupEnabled && restarted.deletionIntent?.phase == .disabled)
        }
        do {
            let original = Subject()
            original.backupEnvelopeStore.refusesDelete = true
            await original.disableEncryptedBackup()
            precondition(original.deletionIntent?.phase == .localCleanupPending)
            let restarted = Subject(keychain: original.backupKeychainStore, envelope: original.backupEnvelopeStore)
            restarted.hub.currentBackupAccountID = "B"
            restarted.backupEnvelopeStore.refusesDelete = false
            await restarted.refreshRemoteBackupStatus()
            precondition(restarted.backupSyncService!.deletes.isEmpty, "durably confirmed remote deletion must not delete again on another account")
            await restarted.disableEncryptedBackup()
            precondition(!restarted.backupEnvelopeStore.exists && !restarted.isBackupEnabled)
            UserDefaults.standard.set(true, forKey: "test-only")
            UserDefaults.standard.set(true, forKey: "automatic-test-only")
            let again = Subject(keychain: restarted.backupKeychainStore, envelope: restarted.backupEnvelopeStore)
            again.loadEncryptedBackupState()
            again.loadAutomaticBackupPreference()
            precondition(!again.isBackupEnabled && !again.isAutomaticBackupEnabled,
                         "durable Off must override stale ordinary preferences: enabled=\(again.isBackupEnabled) automatic=\(again.isAutomaticBackupEnabled) phase=\(String(describing: again.deletionIntent?.phase))")
            await again.refreshRemoteBackupStatus()
            precondition(!again.isBackupEnabled, "metadata cannot reverse explicit Off")
        }
        do {
            let subject = Subject()
            subject.backupKeychainStore.refusesRead = true
            subject.loadEncryptedBackupState()
            await subject.refreshRemoteBackupStatus()
            await subject.attemptUpload()
            precondition(subject.uploads == 0 && subject.backupSyncService!.fetches == 0 && subject.backupSyncService!.deletes.isEmpty)
        }
        do {
            let subject = Subject()
            await subject.clearEncryptedBackup()
            precondition(subject.backupKeychainStore.intentData == nil && subject.backupEnvelopeStore.exists)
            precondition(subject.backupKeychainStore.deletes == 0 && subject.isBackupEnabled, "online-only delete keeps local setup")
        }
        do {
            let subject = Subject()
            subject.backupSyncService!.deleteHook = { throw BackupSyncServiceError.requestFailed(503) }
            await subject.clearEncryptedBackup()
            precondition(subject.remoteBackupStatusUnavailable && subject.remoteBackupAvailable,
                         "failed online-only deletion must retain the existing backup and unavailable status")
            subject.backupSyncService!.deleteHook = nil
            await subject.clearEncryptedBackup()
            precondition(!subject.remoteBackupStatusUnavailable && !subject.remoteBackupAvailable,
                         "confirmed online-only deletion must clear the prior unavailable status")
            precondition(subject.remoteBackupStatus == "No backup")
            precondition(subject.backupSyncService!.deletes == ["A", "A"])
            precondition(subject.backupKeychainStore.intentData == nil && subject.backupEnvelopeStore.exists)
            precondition(subject.backupKeychainStore.deletes == 0 && subject.isBackupEnabled,
                         "successful retry must preserve local backup setup")
        }
        do {
            let subject = Subject()
            subject.backupKeychainStore.failsAfterSave = true
            await subject.disableEncryptedBackup()
            await subject.attemptUpload()
            precondition(subject.backupKeychainStore.intentData != nil)
            precondition(subject.backupSyncService!.deletes.isEmpty && subject.uploads == 0,
                         "an uncertain acknowledged write must immediately reload its persisted fence")
        }
        do {
            let keychain = Keychain()
            keychain.intentData = Data(#"{"version":2,"accountID":"A","phase":"remotePending"}"#.utf8)
            let subject = Subject(keychain: keychain, envelope: Envelope())
            await subject.refreshRemoteBackupStatus()
            await subject.attemptUpload()
            precondition(subject.backupSyncService!.fetches == 0 && subject.uploads == 0)
            precondition(subject.backupSyncService!.deletes.isEmpty && keychain.deletes == 0)
        }
        do {
            let subject = Subject()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            let account = AccountSubject(backup: subject)
            let success = await account.deleteAccount()
            precondition(success && account.accountAuthService.urlSession.deletedIDs == ["A"])
            precondition(subject.deletionIntent?.phase == .disabled && !subject.isBackupMaintenanceInProgress)
            subject.hub.currentBackupAccountID = "B"
            subject.explicitlyEnableForTest()
            precondition(subject.isBackupEnabled && subject.deletionIntent == nil,
                         "confirmed matching account deletion must not strand the new account")
        }
        do {
            let subject = Subject()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            let account = AccountSubject(backup: subject)
            account.accountAuthService.urlSession.hook = { throw BackupSyncServiceError.requestFailed(503) }
            let success = await account.deleteAccount()
            precondition(!success && !subject.isBackupMaintenanceInProgress)
            precondition(subject.deletionIntent?.phase == .disabled && account.accountAuthService.state.accountID == "A")
            account.accountAuthService.urlSession.hook = nil
            let retry = await account.deleteAccount()
            precondition(retry && !subject.isBackupMaintenanceInProgress)
        }
        do {
            let subject = Subject()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            subject.backupKeychainStore.refusesSave = true
            let account = AccountSubject(backup: subject)
            let success = await account.deleteAccount()
            precondition(!success && account.accountAuthService.urlSession.deletedIDs.isEmpty,
                         "an unpersistable backup checkpoint must precede irreversible account deletion")
            precondition(account.accountAuthService.state.accountID == "A" && !subject.isBackupMaintenanceInProgress)
        }
        do {
            let subject = Subject()
            let account = AccountSubject(backup: subject)
            account.accountAuthService.state.accountID = nil
            let success = await account.deleteAccount()
            precondition(!success && account.accountAuthService.urlSession.deletedIDs.isEmpty)
            precondition(account.hub.backup.backupKeychainStore.deletes == 0 && !account.hub.backup.isBackupMaintenanceInProgress)
            precondition(subject.backupEnvelopeStore.exists)
        }
        do {
            let subject = Subject(), gate = Gate()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            let account = AccountSubject(backup: subject)
            account.accountAuthService.urlSession.hook = { await gate.wait() }
            let operation = Task { await account.deleteAccount() }
            await until { gate.continuation != nil }
            account.accountAuthService.state.accountID = "B"
            subject.hub.currentBackupAccountID = "B"
            subject.explicitlyEnableForTest()
            precondition(!subject.isBackupEnabled && subject.isBackupMaintenanceInProgress)
            gate.release()
            let success = await operation.value
            precondition(success && account.accountAuthService.state.accountID == "B")
            precondition(account.accountAuthService.signOuts == 0 && !subject.isBackupMaintenanceInProgress)
            subject.explicitlyEnableForTest()
            precondition(subject.isBackupEnabled)
        }
        do {
            let subject = Subject()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            subject.hub.currentBackupAccountID = "B"
            let account = AccountSubject(backup: subject)
            account.accountAuthService.state.accountID = "B"
            let success = await account.deleteAccount()
            precondition(success && account.accountAuthService.urlSession.deletedIDs == ["B"])
            precondition(subject.deletionIntent?.accountID == "A" && subject.deletionIntent?.phase == .remotePending)
            precondition(subject.backupKeychainStore.deletes == 0 && subject.backupSyncService!.deletes.isEmpty)
            precondition(subject.backupEnvelopeStore.exists && !subject.isBackupMaintenanceInProgress)
        }
        do {
            let subject = Subject()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            subject.backupEnvelopeStore.refusesDelete = true
            let account = AccountSubject(backup: subject)
            let success = await account.deleteAccount()
            precondition(!success && account.accountAuthService.urlSession.deletedIDs.isEmpty)
            precondition(subject.deletionIntent?.phase == .localCleanupPending)
            subject.backupEnvelopeStore.refusesDelete = false
            let restarted = Subject(keychain: subject.backupKeychainStore, envelope: subject.backupEnvelopeStore)
            let retryAccount = AccountSubject(backup: restarted)
            let retry = await retryAccount.deleteAccount()
            precondition(retry && restarted.deletionIntent?.phase == .disabled)
            precondition(restarted.backupSyncService!.deletes.isEmpty,
                         "a confirmed local-cleanup checkpoint must not need another remote backup deletion")
        }
        do {
            let subject = Subject()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            subject.backupEnvelopeStore.refusesDelete = true
            subject.deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: "A")
            precondition(subject.deletionIntent?.phase == .localCleanupPending)
            subject.backupEnvelopeStore.refusesDelete = false
            let restarted = Subject(keychain: subject.backupKeychainStore, envelope: subject.backupEnvelopeStore)
            restarted.hub.currentBackupAccountID = "B"
            await restarted.refreshRemoteBackupStatus()
            await restarted.disableEncryptedBackup()
            precondition(restarted.deletionIntent?.phase == .disabled && restarted.backupSyncService!.deletes.isEmpty)
            restarted.explicitlyEnableForTest()
            precondition(restarted.isBackupEnabled)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.uploadTask = Task { await gate.wait() }
            await until { gate.continuation != nil }
            let account = AccountSubject(backup: subject)
            let operation = Task { await account.deleteAccount() }
            await until { subject.isBackupMaintenanceInProgress }
            account.accountAuthService.state.accountID = "B"
            subject.hub.currentBackupAccountID = "B"
            gate.release()
            let success = await operation.value
            precondition(!success && account.accountAuthService.urlSession.deletedIDs.isEmpty)
            precondition(!subject.isBackupMaintenanceInProgress && subject.backupKeychainStore.deletes == 0)
        }
        do {
            let subject = Subject()
            subject.isBackupMaintenanceInProgress = true
            let account = AccountSubject(backup: subject)
            let success = await account.deleteAccount()
            precondition(!success && account.accountAuthService.urlSession.deletedIDs.isEmpty)
            precondition(subject.isBackupMaintenanceInProgress,
                         "a failed preflight must not release an unrelated operation's maintenance")
        }
        do {
            let subject = Subject(), gate = Gate()
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            subject.reloadForTest()
            subject.backupSyncService!.deleteHook = { await gate.wait() }
            let account = AccountSubject(backup: subject)
            let operation = Task { await account.deleteAccount() }
            await until { gate.continuation != nil }
            account.accountAuthService.state.accountID = "B"
            account.accountAuthService.sessionGeneration &+= 1
            subject.hub.currentBackupAccountID = "B"
            gate.release()
            let success = await operation.value
            precondition(!success && account.accountAuthService.urlSession.deletedIDs.isEmpty)
            precondition(subject.deletionIntent?.phase == .remotePending && subject.backupKeychainStore.deletes == 0)
            precondition(!subject.isBackupMaintenanceInProgress)
        }
        do {
            let subject = Subject(), gate = Gate()
            let account = AccountSubject(backup: subject)
            account.accountAuthService.urlSession.hook = { await gate.wait() }
            let operation = Task { await account.deleteAccount() }
            await until { gate.continuation != nil }
            account.accountAuthService.state.accountID = "B"
            account.accountAuthService.sessionGeneration &+= 1
            subject.hub.currentBackupAccountID = "B"
            await subject.attemptUpload()
            precondition(subject.uploads == 0)
            gate.release()
            let success = await operation.value
            precondition(success && account.accountAuthService.state.accountID == "B")
            precondition(account.accountAuthService.signOuts == 0 && !subject.isBackupMaintenanceInProgress)
            precondition(subject.backupKeychainStore.deletes == 3 && subject.backupEnvelopeStore.exists,
                         "the A lease prevents replacement; confirmed A deletion tears down its secrets only")
        }
        do {
            let subject = Subject()
            UserDefaults.standard.set(true, forKey: "automatic-test-only")
            try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
            let restarted = Subject(keychain: subject.backupKeychainStore, envelope: subject.backupEnvelopeStore)
            restarted.loadAutomaticBackupPreference()
            precondition(!restarted.isAutomaticBackupEnabled && !UserDefaults.standard.bool(forKey: "automatic-test-only"))
            await restarted.disableEncryptedBackup()
            restarted.explicitlyEnableForTest()
            let reenabled = Subject(keychain: restarted.backupKeychainStore, envelope: restarted.backupEnvelopeStore)
            reenabled.loadAutomaticBackupPreference()
            precondition(!reenabled.isAutomaticBackupEnabled,
                         "completed Off must persist Automatic false even when restart already made its cache false")
            precondition(!UserDefaults.standard.bool(forKey: "automatic-test-only"))
        }
        do {
            let subject = Subject()
            await subject.disableEncryptedBackup()
            precondition(!subject.isBackupEnabled && subject.deletionIntent?.phase == .disabled)
            subject.backupKeychainStore.refusesCompletedDeletionClear = true
            subject.explicitlyEnableForTest()
            precondition(!subject.isBackupEnabled && !UserDefaults.standard.bool(forKey: "test-only"),
                         "failed durable Off-marker removal must leave backup Off")
            precondition(subject.deletionIntent?.phase == .disabled)
            precondition(try! subject.backupKeychainStore.loadDeletionIntent()?.phase == .disabled)
            guard case .failed(let message) = subject.encryptedBackupState else {
                fatalError("failed re-enable must expose a visible retryable error while Off")
            }
            precondition(message == "Backup state is unavailable. Unlock your device and try again.")
            precondition(subject.encryptedBackupFailureMessage == message,
                         "the failure projection must remain visible while the master preference is Off")
            subject.backupKeychainStore.refusesCompletedDeletionClear = false
            subject.explicitlyEnableForTest()
            precondition(subject.isBackupEnabled && UserDefaults.standard.bool(forKey: "test-only"))
            precondition(subject.deletionIntent == nil && subject.backupKeychainStore.intentData == nil,
                         "explicit re-enable retry succeeds after Keychain storage recovers")
            guard case .off = subject.encryptedBackupState else {
                fatalError("successful re-enable must restore current local state instead of retaining its obsolete error")
            }
            precondition(subject.encryptedBackupFailureMessage == nil)
            precondition(subject.backupSyncService!.deletes == ["A"] && subject.uploads == 0,
                         "re-enable retries must not repeat deletion or start an upload")
        }
        do {
            let subject = Subject()
            subject.hub.currentBackupAccountID = nil
            subject.backupEnvelopeStore.exists = false
            UserDefaults.standard.set(true, forKey: "test-only")
            subject.loadAutomaticBackupPreference()
            precondition(subject.isBackupEnabled, "unknown remote presence is not consent to clear existing enabled state")
            await subject.disableEncryptedBackup()
            precondition(subject.isBackupEnabled && subject.backupKeychainStore.deletes == 0)
            precondition(subject.backupSyncService!.deletes.isEmpty && subject.deletionIntent == nil)
            subject.hub.currentBackupAccountID = "A"
            await subject.disableEncryptedBackup()
            precondition(!subject.isBackupEnabled && subject.backupSyncService!.deletes == ["A"])
        }
        do {
            let subject = Subject()
            let previousUpload = Date(timeIntervalSince1970: 1_700_500_000)
            subject.backupEnvelopeStore.recordUpload(at: previousUpload)
            let account = AccountSubject(backup: subject)
            let deleted = await account.deleteAccount()
            precondition(deleted && subject.backupEnvelopeStore.exists && subject.backupKeychainStore.deviceSecret == nil)
            subject.hub.currentBackupAccountID = "B"
            subject.backupSyncService = nil
            do { try await subject.turnOnEncryptedBackup(recoveryPhrase: "fixture recovery phrase") }
            catch { fatalError("explicit setup must replace an orphan after confirmed account deletion: \(error)") }
            precondition(subject.backupEnvelopeStore.saveCount == 1 && subject.backupKeychainStore.deviceSecret == "new-device-key")
            precondition(subject.backupEnvelopeStore.markersAtSave.count == 1 && subject.backupEnvelopeStore.markersAtSave[0] == nil,
                         "old upload evidence must be cleared before publishing the replacement envelope")
            let restarted = Subject(keychain: subject.backupKeychainStore, envelope: subject.backupEnvelopeStore)
            restarted.hub.currentBackupAccountID = "B"
            restarted.loadEncryptedBackupState()
            guard case .waitingForSignIn = restarted.encryptedBackupState else {
                fatalError("restart immediately after orphan replacement must not claim the new envelope was uploaded")
            }
            do {
                try await subject.turnOnEncryptedBackup(recoveryPhrase: "second phrase")
                fatalError("repeat setup must not replace the newly configured envelope")
            } catch EncryptedBackupError.supersededByConcurrentConfigurationChange {} catch { fatalError("unexpected error") }
            precondition(subject.backupEnvelopeStore.saveCount == 1)
        }
        do {
            let subject = Subject()
            let original = subject.backupEnvelopeStore.envelope, previousUpload = Date(timeIntervalSince1970: 1_700_500_000)
            subject.backupEnvelopeStore.recordUpload(at: previousUpload)
            do {
                try await subject.turnOnEncryptedBackup(recoveryPhrase: "fixture")
                fatalError("configured envelope must stay protected")
            } catch EncryptedBackupError.supersededByConcurrentConfigurationChange {} catch { fatalError("unexpected error") }
            precondition(subject.backupEnvelopeStore.saveCount == 0 && subject.backupKeychainStore.deviceSecret == "original-device-key")
            precondition(subject.backupEnvelopeStore.envelope == original && subject.backupEnvelopeStore.lastUploadedAt() == previousUpload)
        }
        do {
            let subject = Subject()
            let original = subject.backupEnvelopeStore.envelope, previousUpload = Date(timeIntervalSince1970: 1_700_500_000)
            subject.backupEnvelopeStore.recordUpload(at: previousUpload)
            subject.backupKeychainStore.deviceSecret = nil
            subject.backupKeychainStore.refusesDeviceSecretRead = true
            do {
                try await subject.turnOnEncryptedBackup(recoveryPhrase: "fixture")
                fatalError("unreadable Keychain is not proof of an absent device secret")
            } catch DeviceSecretReadError.unavailable {} catch { fatalError("the original Keychain read error must propagate") }
            precondition(subject.backupEnvelopeStore.saveCount == 0 && subject.backupKeychainStore.deviceSecret == nil)
            precondition(subject.backupEnvelopeStore.envelope == original && subject.backupEnvelopeStore.lastUploadedAt() == previousUpload)
        }
        do {
            let subject = Subject()
            let original = subject.backupEnvelopeStore.envelope, previousUpload = Date(timeIntervalSince1970: 1_700_500_000)
            subject.backupEnvelopeStore.recordUpload(at: previousUpload)
            subject.backupKeychainStore.deviceSecret = nil
            subject.backupKeychainStore.refusesDeviceSecretSave = true
            do {
                try await subject.turnOnEncryptedBackup(recoveryPhrase: "fixture")
                fatalError("setup cannot publish a replacement before the device key is saved")
            } catch DeviceSecretReadError.unavailable {} catch { fatalError("unexpected key persistence error") }
            precondition(subject.backupEnvelopeStore.saveCount == 0 && subject.backupKeychainStore.deviceSecret == nil)
            precondition(subject.backupEnvelopeStore.envelope == original && subject.backupEnvelopeStore.lastUploadedAt() == previousUpload,
                         "a failed new-key save must preserve the old envelope and its upload evidence")
        }
        for maintenance in [false, true] {
            let subject = Subject()
            let original = subject.backupEnvelopeStore.envelope, previousUpload = Date(timeIntervalSince1970: 1_700_500_000)
            subject.backupEnvelopeStore.recordUpload(at: previousUpload)
            subject.backupKeychainStore.deviceSecret = nil
            if maintenance { subject.isBackupMaintenanceInProgress = true }
            else {
                try! subject.backupKeychainStore.saveDeletionIntent(BackupDeletionIntent(accountID: "A"))
                subject.reloadForTest()
            }
            do {
                try await subject.turnOnEncryptedBackup(recoveryPhrase: "fixture")
                fatalError("an orphan must not bypass backup maintenance/deletion fences")
            } catch EncryptedBackupError.supersededByConcurrentConfigurationChange {} catch { fatalError("unexpected error") }
            precondition(subject.backupEnvelopeStore.saveCount == 0 && subject.backupKeychainStore.deviceSecretReads == 0)
            precondition(subject.backupEnvelopeStore.envelope == original && subject.backupEnvelopeStore.lastUploadedAt() == previousUpload)
        }
        // F238-01/02: controller-owned confirmed metadata survives lifecycle refresh.
        do {
            let subject = Subject(), gate = Gate()
            let stamp = Date(timeIntervalSince1970: 1_789_210_580)
            subject.backupSyncService!.fetchResult = { BackupRemoteMetadata(userID: $0, uploadedAt: stamp) }
            await subject.refreshRemoteBackupStatus()
            let known = subject.backupStatusSubtitle
            precondition(known == String(format: "Last updated at %@, %@",
                stamp.formatted(date: .omitted, time: .shortened), stamp.formatted(date: .abbreviated, time: .omitted)))
            subject.backupSyncService!.fetchHook = { await gate.wait() }
            let first = Task { await subject.refreshRemoteBackupStatus() }
            await until { gate.continuation != nil }
            let second = Task { await subject.refreshRemoteBackupStatus() }
            await Task.yield()
            precondition(subject.backupSyncService!.fetches == 2, "overlapping foreground/view reads must coalesce")
            precondition(subject.backupStatusSubtitle == known && subject.remoteBackupAvailable)
            gate.release(); await first.value; await second.value
            precondition(subject.backupStatusSubtitle == known)
        }
        do {
            let subject = Subject()
            subject.backupSyncService!.fetchResult = { _ in nil }
            await subject.refreshRemoteBackupStatus()
            precondition(subject.backupStatusSubtitle == "No backup")
            subject.backupSyncService!.fetchHook = { throw BackupSyncServiceError.requestFailed(503) }
            await subject.refreshRemoteBackupStatus()
            precondition(subject.backupStatusSubtitle == "No backup" && subject.remoteBackupStatusUnavailable)
            subject.backupSyncService!.fetchHook = nil
            subject.backupSyncService!.fetchResult = { BackupRemoteMetadata(userID: $0, uploadedAt: nil) }
            await subject.refreshRemoteBackupStatus()
            precondition(subject.backupStatusSubtitle == "Backup available" && !subject.remoteBackupStatusUnavailable)
        }
        do {
            let subject = Subject(), gate = Gate()
            await subject.refreshRemoteBackupStatus()
            subject.backupSyncService!.fetchHook = { await gate.wait(); throw CancellationError() }
            let cancelled = Task { await subject.refreshRemoteBackupStatus() }
            await until { gate.continuation != nil }
            cancelled.cancel()
            precondition(subject.backupStatusSubtitle == "Backup available")
            gate.release(); await cancelled.value
            precondition(subject.backupStatusSubtitle == "Backup available" && subject.remoteBackupStatusUnavailable)
        }
        do {
            let subject = Subject()
            subject.backupSyncService!.fetchHook = { throw BackupSyncServiceError.requestFailed(503) }
            await subject.refreshRemoteBackupStatus()
            precondition(subject.backupStatusSubtitle == "Backup status unavailable")
            precondition(!subject.remoteBackupAvailable && subject.remoteBackupStatusUnavailable)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.backupSyncService!.fetchResult = { BackupRemoteMetadata(userID: $0, uploadedAt: Date(timeIntervalSince1970: 1)) }
            await subject.refreshRemoteBackupStatus()
            subject.backupSyncService!.fetchHook = { await gate.wait() }
            let stale = Task { await subject.refreshRemoteBackupStatus() }
            await until { gate.continuation != nil }
            subject.hub.currentBackupAccountID = "B"
            precondition(subject.backupStatusSubtitle == "Checking for a backup…", "a synchronous account switch must hide A's timestamp before refresh")
            subject.backupSyncService!.fetchHook = nil
            subject.backupSyncService!.fetchResult = { _ in nil }
            await subject.refreshRemoteBackupStatus()
            gate.release(); await stale.value
            precondition(subject.backupStatusSubtitle == "No backup" && subject.remoteBackupAccountID == "B")
            subject.hub.currentBackupAccountID = nil
            subject.loadEncryptedBackupState()
            precondition(subject.backupStatusSubtitle == "Backup status unavailable" && !subject.remoteBackupAvailable)
        }
        do {
            let subject = Subject()
            await subject.disableEncryptedBackup()
            let fetches = subject.backupSyncService!.fetches
            for _ in 0..<3 { await subject.refreshRemoteBackupStatus() }
            precondition(subject.backupStatusSubtitle == "No backup" && subject.backupSyncService!.fetches == fetches)
            subject.explicitlyEnableForTest()
            await subject.refreshRemoteBackupStatus()
            precondition(subject.remoteBackupAvailable && subject.backupSyncService!.fetches == fetches + 1,
                         "explicit enable discovers a server-only copy without local setup or upload")
            precondition(!subject.backupEnvelopeStore.exists && subject.uploads == 0)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.backupSyncService!.fetchResult = { _ in nil }
            subject.backupSyncService!.fetchHook = { await gate.wait() }
            let stale = Task { await subject.refreshRemoteBackupStatus() }
            await until { gate.continuation != nil }
            subject.backupSyncService!.fetchHook = nil
            subject.backupSyncService!.fetchResult = { BackupRemoteMetadata(userID: $0, uploadedAt: nil) }
            let uploaded = await subject.uploadForTest()
            precondition(uploaded && subject.remoteBackupAvailable)
            guard let receipt = subject.backupEnvelopeStore.lastUploadedAt() else { fatalError("upload receipt missing") }
            let freshStatus = String(format: "Last updated at %@, %@",
                receipt.formatted(date: .omitted, time: .shortened), receipt.formatted(date: .abbreviated, time: .omitted))
            gate.release(); await stale.value
            precondition(subject.remoteBackupAvailable && subject.backupStatusSubtitle == freshStatus,
                         "a metadata read preceding upload must not resurrect absence or erase its receipt")
        }
        do {
            let subject = Subject()
            let oldUpload = Date(timeIntervalSince1970: 1_700_500_000)
            subject.backupSyncService!.fetchResult = { BackupRemoteMetadata(userID: $0, uploadedAt: oldUpload) }
            await subject.refreshRemoteBackupStatus()
            let oldStatus = subject.backupStatusSubtitle
            subject.backupSyncService!.uploadHook = { throw BackupSyncServiceError.requestFailed(503) }
            let failedUpload = await subject.uploadForTest()
            precondition(!failedUpload)
            precondition(subject.backupStatusSubtitle == oldStatus,
                         "a failed upload must not replace confirmed metadata")
            subject.backupSyncService!.uploadHook = nil
            let successfulUpload = await subject.uploadForTest()
            precondition(successfulUpload)
            guard let receipt = subject.backupEnvelopeStore.lastUploadedAt() else { fatalError("upload receipt missing") }
            let freshStatus = String(format: "Last updated at %@, %@",
                receipt.formatted(date: .omitted, time: .shortened), receipt.formatted(date: .abbreviated, time: .omitted))
            precondition(freshStatus != oldStatus && subject.backupStatusSubtitle == freshStatus,
                         "a successful upload must replace the displayed older metadata timestamp")
        }
        // F239-03: only this setup's committed envelope/account can complete its page.
        do {
            let subject = Subject(), gate = Gate()
            subject.backupKeychainStore.deviceSecret = nil
            subject.backupSyncService!.uploadHook = { await gate.wait() }
            try! await subject.turnOnEncryptedBackup(recoveryPhrase: "synthetic fixture")
            let id = subject.setupUploadProgress!.id
            await until { gate.continuation != nil }
            precondition(!subject.isSetupUploadConfirmed(attemptID: id) && subject.setupUploadProgress?.state == .uploading)
            let key = subject.backupKeychainStore.deviceSecret, envelope = subject.backupEnvelopeStore.envelope
            await subject.retrySetupUpload(attemptID: id)
            precondition(subject.uploads == 1, "repeated retries cannot overlap the active setup upload")
            gate.release()
            await until { subject.setupUploadProgress?.state == .uploaded }
            precondition(subject.isSetupUploadConfirmed(attemptID: id))
            precondition(subject.backupKeychainStore.deviceSecret == key && subject.backupEnvelopeStore.envelope == envelope)
            await subject.retrySetupUpload(attemptID: id)
            precondition(subject.uploads == 1, "an already confirmed setup cannot upload twice through its retry action")
        }
        do {
            let subject = Subject()
            subject.backupKeychainStore.deviceSecret = nil
            let previousUpload = Date(timeIntervalSince1970: 1_700_500_000)
            subject.backupEnvelopeStore.recordUpload(at: previousUpload)
            subject.encryptedBackupState = .synced(estimatedByteSize: 1, uploadedAt: Date())
            subject.backupSyncService!.uploadHook = { throw BackupSyncServiceError.requestFailed(503) }
            try! await subject.turnOnEncryptedBackup(recoveryPhrase: "synthetic fixture")
            let id = subject.setupUploadProgress!.id
            await until { if case .failed = subject.setupUploadProgress?.state { return true }; return false }
            precondition(!subject.isSetupUploadConfirmed(attemptID: id), "cached sync and older server metadata are not this attempt's receipt")
            precondition(subject.backupEnvelopeStore.lastUploadedAt() == nil)
            let restarted = Subject(keychain: subject.backupKeychainStore, envelope: subject.backupEnvelopeStore)
            restarted.loadEncryptedBackupState()
            guard case .waitingForSignIn = restarted.encryptedBackupState else {
                fatalError("failed replacement upload must remain unuploaded after restart")
            }
            let key = subject.backupKeychainStore.deviceSecret, envelope = subject.backupEnvelopeStore.envelope
            subject.backupSyncService!.uploadHook = nil
            await subject.retrySetupUpload(attemptID: id)
            precondition(subject.isSetupUploadConfirmed(attemptID: id) && subject.backupEnvelopeStore.saveCount == 1)
            precondition(subject.backupKeychainStore.deviceSecret == key && subject.backupEnvelopeStore.envelope == envelope)
            guard let confirmedUpload = subject.backupEnvelopeStore.lastUploadedAt() else { fatalError("successful retry records fresh upload evidence") }
            precondition(confirmedUpload > previousUpload)
            restarted.loadEncryptedBackupState()
            guard case .synced(_, let uploadedAt) = restarted.encryptedBackupState, uploadedAt == confirmedUpload else {
                fatalError("only the confirmed new upload may be reported as synced after restart")
            }
        }
        for changeAccount in [false, true] {
            let subject = Subject(), gate = Gate()
            subject.backupKeychainStore.deviceSecret = nil
            subject.backupSyncService!.uploadHook = { await gate.wait() }
            try! await subject.turnOnEncryptedBackup(recoveryPhrase: "synthetic fixture")
            let id = subject.setupUploadProgress!.id
            await until { gate.continuation != nil }
            if changeAccount { subject.hub.currentBackupAccountID = "B" }
            else { subject.backupEnvelopeStore.envelope = ZeroKnowledgeBackupEnvelope() }
            gate.release()
            await until { subject.setupUploadProgress?.state == .unavailable }
            precondition(!subject.isSetupUploadConfirmed(attemptID: id))
            let uploads = subject.uploads
            await subject.retrySetupUpload(attemptID: id)
            precondition(subject.uploads == uploads, "stale attempt may not replace another envelope or upload into B")
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.backupKeychainStore.deviceSecret = nil
            subject.backupSyncService!.uploadHook = { await gate.wait() }
            try! await subject.turnOnEncryptedBackup(recoveryPhrase: "synthetic fixture")
            let id = subject.setupUploadProgress!.id
            await until { gate.continuation != nil }
            let disable = Task { await subject.disableEncryptedBackup() }
            await until { subject.isBackupMaintenanceInProgress }
            gate.release(); await disable.value
            precondition(!subject.isSetupUploadConfirmed(attemptID: id) && !subject.isBackupEnabled)
            precondition(subject.backupKeychainStore.deviceSecret == nil && !subject.backupEnvelopeStore.exists)
        }
        do {
            let subject = Subject()
            subject.backupKeychainStore.deviceSecret = nil
            subject.backupSyncService = nil
            try! await subject.turnOnEncryptedBackup(recoveryPhrase: "synthetic fixture")
            let id = subject.setupUploadProgress!.id
            await until { if case .failed = subject.setupUploadProgress?.state { return true }; return false }
            precondition(!subject.isSetupUploadConfirmed(attemptID: id) && subject.backupEnvelopeStore.exists,
                         "unavailable upload preserves committed local setup without online success")
        }
        do {
            let subject = Subject()
            subject.backupKeychainStore.deviceSecret = nil
            try! await subject.turnOnEncryptedBackup(recoveryPhrase: "synthetic fixture")
            let id = subject.setupUploadProgress!.id
            await until { subject.setupUploadProgress?.state == .uploaded }
            precondition(subject.isSetupUploadConfirmed(attemptID: id) && subject.uploads == 1)
        }
        do {
            let subject = Subject()
            subject.backupKeychainStore.deviceSecret = nil
            subject.backupSyncService!.uploadHook = { throw CancellationError() }
            try! await subject.turnOnEncryptedBackup(recoveryPhrase: "synthetic fixture")
            let id = subject.setupUploadProgress!.id
            await until { if case .failed = subject.setupUploadProgress?.state { return true }; return false }
            precondition(!subject.isSetupUploadConfirmed(attemptID: id) && subject.backupEnvelopeStore.exists)
            precondition(subject.backupKeychainStore.deviceSecret != nil && subject.isBackupEnabled,
                         "a cancelled upload preserves committed setup and never claims online completion")
        }
        print("PASS: 53 production-method backup/account lifecycle, metadata continuity, setup upload and storage-failure scenarios")
        let second: UInt64 = 1_000_000_000
        // A completed relative wait must not be rejected because wall time moved back.
        do {
            ControlledTime.reset()
            let subject = Subject()
            subject.scheduleAutomaticBackupAfterConfigurationChange()
            let task = subject.automaticBackupTask!
            await until { ControlledTime.pending.count == 1 }
            ControlledTime.wallNow = ControlledTime.wallNow.addingTimeInterval(-3_600)
            ControlledTime.advance(by: 300 * second)
            await task.value
            precondition(subject.uploads == 1, "wall-clock rollback must not permanently drop the completed five-minute automatic backup")
            precondition(subject.backupSyncService!.uploads == ["A"] && subject.localReseals == 1)
        }
        // A forward wall-clock correction cannot shorten the monotonic idle interval.
        do {
            ControlledTime.reset()
            let subject = Subject()
            subject.scheduleAutomaticBackupAfterConfigurationChange()
            let task = subject.automaticBackupTask!
            await until { ControlledTime.pending.count == 1 }
            ControlledTime.wallNow = ControlledTime.wallNow.addingTimeInterval(86_400)
            ControlledTime.advance(by: 299 * second)
            precondition(subject.uploads == 0 && ControlledTime.pending.count == 1)
            ControlledTime.advance(by: second)
            await task.value
            precondition(subject.uploads == 1)
        }
        // A newer edit owns a new full interval, even if the cancelled sleeper returns.
        do {
            ControlledTime.reset()
            let subject = Subject()
            subject.scheduleAutomaticBackupAfterConfigurationChange()
            let oldTask = subject.automaticBackupTask!
            await until { ControlledTime.pending.count == 1 }
            ControlledTime.advance(by: 120 * second)
            subject.scheduleAutomaticBackupAfterConfigurationChange()
            let newTask = subject.automaticBackupTask!
            await until { ControlledTime.pending.count == 2 }
            ControlledTime.advance(by: 180 * second)
            await oldTask.value
            precondition(subject.uploads == 0 && ControlledTime.pending.count == 1)
            ControlledTime.advance(by: 120 * second)
            await newTask.value
            precondition(subject.uploads == 1 && subject.localReseals == 2)
        }
        // Existing preference, maintenance, deletion, lifecycle and account gates
        // remain authoritative after the timer has elapsed.
        for change in ["automatic-off", "maintenance", "deletion-fence", "lifecycle", "account", "signed-out"] {
            ControlledTime.reset()
            let subject = Subject()
            subject.scheduleAutomaticBackupAfterConfigurationChange()
            let task = subject.automaticBackupTask!
            await until { ControlledTime.pending.count == 1 }
            switch change {
            case "automatic-off": subject.setAutomaticBackupEnabled(false)
            case "maintenance": subject.isBackupMaintenanceInProgress = true
            case "deletion-fence": subject.deletionFenceReadable = false
            case "lifecycle": subject.lifecycleGeneration &+= 1
            case "account": subject.hub.currentBackupAccountID = "B"
            default: subject.hub.currentBackupAccountID = nil
            }
            ControlledTime.advance(by: 300 * second)
            await task.value
            precondition(subject.uploads == 0, "delayed automatic upload must honor \(change)")
            if change == "automatic-off" {
                subject.setAutomaticBackupEnabled(true)
                precondition(subject.automaticBackupTask == nil, "re-enabling the preference cannot revive the cancelled attempt")
            }
        }
        do {
            ControlledTime.reset()
            let subject = Subject()
            subject.hub.libraryOriginatesFromLaunchReseed = true
            subject.scheduleAutomaticBackupAfterConfigurationChange()
            precondition(subject.automaticBackupTask == nil && subject.localReseals == 0,
                         "the launch-reseed guard still precedes resealing and scheduling")
        }
        print("PASS: 10 controlled-time production scheduling scenarios (rollback, forward jump, trailing replacement and six ownership/availability fences, launch reseed)")
        for change in ["account", "lifecycle", "unchanged"] {
            ControlledTime.reset()
            let subject = Subject(), gate = Gate()
            subject.uploadChildEntryHook = { await gate.wait() }
            subject.scheduleAutomaticBackupAfterConfigurationChange()
            let task = subject.automaticBackupTask!
            await until { ControlledTime.pending.count == 1 }
            ControlledTime.advance(by: 300 * second)
            await until { gate.continuation != nil }
            precondition(subject.uploads == 0, "the timer passed but the upload child has not started")
            if change == "account" { subject.hub.currentBackupAccountID = "B" }
            if change == "lifecycle" { subject.lifecycleGeneration &+= 1 }
            gate.release()
            await task.value
            if change == "unchanged" {
                precondition(subject.backupSyncService!.uploads == ["A"])
            } else {
                precondition(subject.uploads == 0, "queued automatic A upload must not adopt changed \(change) at child entry")
            }
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.uploadChildEntryHook = { await gate.wait() }
            let task = Task { await subject.backUpNow() }
            await until { gate.continuation != nil }
            subject.hub.currentBackupAccountID = "B"
            gate.release(); await task.value
            precondition(subject.uploads == 0, "a queued manual request also retains its initiating account")
            subject.uploadChildEntryHook = nil
            await subject.backUpNow()
            precondition(subject.backupSyncService!.uploads == ["B"], "an explicit new manual backup still uploads for the current account")
        }
        print("PASS: 4 controlled child-entry ownership scenarios (scheduled account/lifecycle/unchanged and explicit manual retry)")
        print("PASS: 68 total production-method backup lifecycle and automatic scheduling scenarios")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lava-backup-lifecycle-') as directory:
    path = Path(directory)
    swift = path / 'Lifecycle.swift'
    intent = (root / 'Sources/LavaSecAppServices/BackupDeletionIntent.swift').read_text()
    schedule_source = (root / 'Sources/LavaSecAppServices/BackupRemoteMetadata.swift').read_text()
    schedule_policy = schedule_source[schedule_source.index('public struct AutomaticBackupSchedule:'):]
    setup_records = source[source.index('struct BackupSetupUploadProgress:'):source.index('/// The narrow hub surface')]
    stubs = stubs.replace('    // ACTUAL_AUTOMATIC_SCHEDULE_FIELDS', schedule_field + '\n' + delay_field)
    stubs = stubs.replace('    // ACTUAL_STORE_MARKER_METHODS', store_marker_methods)
    swift.write_text(intent + schedule_policy + setup_records + stubs + methods + account_stubs + account_methods + bridge_stubs + bridge_methods + controller_stubs + controller_methods + tests)
    env = os.environ.copy()
    env['CLANG_MODULE_CACHE_PATH'] = '/tmp/lava-backup-lifecycle-clang'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors', str(swift), '-o', str(path / 'tests')], check=True, env=env)
    subprocess.run([str(path / 'tests')], check=True, env=env)
