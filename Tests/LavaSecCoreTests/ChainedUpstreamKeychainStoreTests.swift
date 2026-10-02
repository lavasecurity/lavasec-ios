import CryptoKit
import Foundation
import Security
import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The commit protocol: what a reader sees at every point a rotation can be interrupted.
///
/// The live `SecItem*` round-trip is not exercisable in host unit tests, so the key half runs
/// against an injected backend and the configuration half against a real temp directory. That
/// is deliberate rather than a compromise: the properties this slice has to hold are about the
/// ORDER of the two writes and what survives an interruption, and none of them is visible in a
/// query dictionary.
final class ChainedUpstreamKeychainStoreTests: XCTestCase {
    private typealias Failure = ChainedUpstreamSecretStoreFailure
    private typealias Naming = ChainedUpstreamSecretNaming

    /// A dictionary standing in for the Keychain. `add` is additive, matching the production
    /// backend — an upsert here would hide the bug it exists to prevent.
    private final class FakeKeyItems: ChainedUpstreamKeyItemStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        /// Fires inside `accounts()`, so a test can stage a rotation landing mid-sweep.
        var beforeEnumeration: (@Sendable () -> Void)?
        /// Fires inside `delete(account:)`, so a test can stage a rotation landing in the gap
        /// between the sweep's post-enumeration recheck and the deletes that recheck
        /// authorized — the window the recheck itself cannot cover.
        var beforeDelete: (@Sendable () -> Void)?
        var addFailure: Error?
        var loadFailure: Error?
        var beforeLoad: (@Sendable () throws -> Void)?
        /// Fires AFTER a key is staged, so a test can make the container unwritable in the
        /// window between the Keychain add and the configuration commit — the only place a
        /// staged key can be stranded.
        var afterAdd: (@Sendable () -> Void)?

        func add(_ key: Data, account: String) throws {
            if let addFailure { throw addFailure }
            defer { afterAdd?() }
            lock.lock()
            defer { lock.unlock() }
            guard items[account] == nil else {
                throw ChainedUpstreamSecretStoreFailure.keychainRefused(errSecDuplicateItem)
            }
            items[account] = key
        }

        func load(account: String) throws -> Data? {
            try beforeLoad?()
            if let loadFailure { throw loadFailure }
            lock.lock()
            defer { lock.unlock() }
            return items[account]
        }

        func delete(account: String) throws {
            beforeDelete?()
            lock.lock()
            defer { lock.unlock() }
            items[account] = nil
        }

        func accounts() throws -> [String] {
            beforeEnumeration?()
            lock.lock()
            defer { lock.unlock() }
            return Array(items.keys)
        }

        var storedAccounts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(items.keys).sorted()
        }
    }

    private var container: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chained-upstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let container {
            // Restore any permission a locked-file fixture removed, or the cleanup fails.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: container.path)
            for filename in [
                Naming.configurationFilename(for: .production),
                Naming.writeLockFilename(for: .production),
            ] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: container.appendingPathComponent(filename).path)
            }
            try? FileManager.default.removeItem(at: container)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    func testEntryReadDuringRotationIsTransientRatherThanMissingSecret() throws {
        let keys = FakeKeyItems()
        let rotating = makeStore(keys)
        let first = try rotating.saveHop(index: 0, name: "Entry", replacement: rotation(), expectedGeneration: nil)
        _ = try rotating.saveHop(index: 1, name: "Exit", replacement: rotation(host: "198.51.100.2"), expectedGeneration: first)
        let config = try XCTUnwrap(rotating.loadStoredConfigurationRecord()).configuration
        let replacement = try ChainedUpstreamRotation(configuration: config, privateKey: Data(repeating: 9, count: 32),
            precedingRotations: [ChainedUpstreamRotation(configuration: config.precedingHops[0], privateKey: Data(repeating: 7, count: 32))])
        keys.beforeLoad = { keys.beforeLoad = nil; _ = try rotating.commit(replacement) }
        XCTAssertThrowsError(try ChainedSessionCredentialReader.readEntry(store: rotating, latchedConfiguration: config)) {
            XCTAssertEqual($0 as? ChainedSessionBuildFailure, .credentialsUnavailable)
        }
        XCTAssertNoThrow(try ChainedSessionCredentialReader.readEntry(store: rotating, latchedConfiguration: config))
    }
    func testProfileCommitKeepsPendingPreferencesRetryableWithoutRewritingKeys() throws {
        var draft = try ChainedUpstreamEditDraft(id: "retry", generation: nil, configurations: [])
        try draft.save(index: 0, name: "Saved", replacement: rotation())
        draft.didCommitProfiles(generation: 7, awaitingSettings: true)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertFalse(draft.hasProfileChanges)
        XCTAssertNil(draft.rows.first?.replacement)
        XCTAssertEqual(draft.generation, 7)
        draft.didCommitSettings()
        XCTAssertFalse(draft.hasChanges)
    }
    func testLegacyStrictNestedSchemaCannotSilentlyBecomeIndependent() throws {
        let store = makeStore(FakeKeyItems())
        _ = try store.commit(rotation())
        let url = container.appendingPathComponent(Naming.configurationFilename(for: .production))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        envelope["schema"] = 2
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        XCTAssertThrowsError(try store.loadStoredConfigurationRecord()) { XCTAssertEqual($0 as? Failure, .configurationUnusable) }
    }

    func testRowActivationSelectsMatchingRuntimeCredentialsAndPreservesDisabledSecrets() throws {
        let store = makeStore(FakeKeyItems())
        let one = try store.saveHop(index: 0, name: "First", replacement: rotation(key: Data(repeating: 3, count: 32)), expectedGeneration: nil)
        let generation = try store.saveHop(index: 1, name: "Second", replacement: rotation(host: "198.51.100.2", key: Data(repeating: 9, count: 32)), expectedGeneration: one)
        var draft = try ChainedUpstreamEditDraft(id: "switch", generation: generation, configurations: XCTUnwrap(store.loadStoredConfigurationRecord()).configuration.orderedHops)
        try draft.setEnabled(false, index: 1)
        XCTAssertEqual(try store.loadConfiguration()?.0.orderedHops.count, 2, "Draft changes cannot alter the live credential projection.")
        let firstOnly = try store.commitEdits(draft)
        draft.didCommitProfiles(generation: firstOnly)
        XCTAssertEqual(try store.loadConfiguration()?.0.displayName, "First")
        XCTAssertEqual(try store.loadPrivateKey()?.privateKey, Data(repeating: 3, count: 32))
        XCTAssertEqual(try store.loadStoredKeyMaterial()?.privateKey, Data(repeating: 9, count: 32), "The disabled second secret remains saved.")
        try draft.setEnabled(false, index: 0)
        let none = try store.commitEdits(draft)
        draft.didCommitProfiles(generation: none)
        XCTAssertNil(try store.loadConfiguration())
        XCTAssertNil(try store.loadPrivateKey())
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.orderedHops.count, 2)
        try draft.setEnabled(true, index: 1)
        _ = try store.commitEdits(draft)
        XCTAssertEqual(try store.loadConfiguration()?.0.displayName, "Second")
        XCTAssertEqual(try store.loadPrivateKey()?.privateKey, Data(repeating: 9, count: 32))
    }

    func testPageDraftDoesNotWriteUntilCommitAndPreservesRetainedHopIdentity() throws {
        let keys = FakeKeyItems(); let store = makeStore(keys)
        let first = try store.commit(rotation())
        let second = try store.saveHop(index: 1, name: "Exit", replacement: rotation(host: "198.51.100.2", key: Data(repeating: 9, count: 32)), expectedGeneration: first)
        let original = try XCTUnwrap(store.loadStoredConfigurationRecord())
        var draft = try ChainedUpstreamEditDraft(id: "page", generation: second, configurations: original.configuration.orderedHops)
        XCTAssertFalse(draft.hasChanges)
        try draft.remove(index: 0)
        try draft.save(index: 0, name: "Retained exit", replacement: nil)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.generation, second)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.orderedHops.count, 2)
        XCTAssertNil(draft.rows[0].replacement)
        _ = try store.commitEdits(draft)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.displayName, "Retained exit")
        XCTAssertEqual(try store.loadStoredKeyMaterial()?.privateKey, Data(repeating: 9, count: 32))
        XCTAssertNil(try store.loadStoredEntryKeyMaterial())
        XCTAssertThrowsError(try store.commitEdits(draft))
    }

    func testNewPageDraftStagesBothHopsAndDiscardLeavesStoreEmpty() throws {
        let keys = FakeKeyItems(); let store = makeStore(keys)
        var draft = try ChainedUpstreamEditDraft(id: "page", generation: nil, configurations: [])
        try draft.save(index: 0, name: "Entry", replacement: rotation())
        try draft.save(index: 1, name: "Exit", replacement: rotation(host: "198.51.100.2"))
        XCTAssertTrue(draft.containsFullTunnel)
        XCTAssertNil(try store.loadStoredConfigurationRecord())
        XCTAssertTrue(keys.storedAccounts.isEmpty)
        let generation = try store.commitEdits(draft)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.orderedHops.map(\.displayName), ["Entry", "Exit"])
        draft.didCommitProfiles(generation: generation)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(draft.rows.allSatisfy { $0.replacement == nil })
    }

    func testSwappingSavedRowsStagesOrderAndKeepsEachRowsKeysAtCommit() throws {
        let store = makeStore(FakeKeyItems())
        let first = try store.saveHop(index: 0, name: "Entry", replacement: rotation(key: Data(repeating: 3, count: 32)), expectedGeneration: nil)
        let generation = try store.saveHop(index: 1, name: "Exit", replacement: rotation(host: "198.51.100.2", key: Data(repeating: 9, count: 32)), expectedGeneration: first)
        let record = try XCTUnwrap(store.loadStoredConfigurationRecord())
        var draft = try ChainedUpstreamEditDraft(id: "swap", generation: generation, configurations: record.configuration.orderedHops)
        try draft.swapOrder()
        XCTAssertEqual(draft.rows.map(\.configuration.displayName), ["Exit", "Entry"])
        XCTAssertEqual(draft.rows.map(\.originalIndex), [1, 0])
        XCTAssertTrue(draft.hasChanges)
        XCTAssertTrue(draft.rows.allSatisfy { $0.replacement == nil })
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.generation, generation)
        try draft.swapOrder()
        XCTAssertFalse(draft.hasChanges, "Swapping twice restores the saved order without a write.")
        try draft.swapOrder()
        _ = try store.commitEdits(draft)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.orderedHops.map(\.displayName), ["Exit", "Entry"])
        XCTAssertEqual(try store.loadStoredEntryKeyMaterial()?.privateKey, Data(repeating: 9, count: 32))
        XCTAssertEqual(try store.loadStoredKeyMaterial()?.privateKey, Data(repeating: 3, count: 32))
    }

    func testSwapPreservesNewReplacementAlongsideRetainedSavedKeys() throws {
        let store = makeStore(FakeKeyItems())
        let generation = try store.commit(rotation(key: Data(repeating: 3, count: 32)))
        let record = try XCTUnwrap(store.loadStoredConfigurationRecord())
        var draft = try ChainedUpstreamEditDraft(id: "swap", generation: generation, configurations: record.configuration.orderedHops)
        try draft.save(index: 1, name: "New", replacement: rotation(host: "198.51.100.2", key: Data(repeating: 9, count: 32)))
        try draft.swapOrder()
        XCTAssertNil(draft.rows[0].originalIndex)
        XCTAssertNotNil(draft.rows[0].replacement)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.generation, generation)
        XCTAssertEqual(try store.loadConfiguration()?.0.orderedHops.count, 1)
        XCTAssertEqual(try store.loadPrivateKey()?.privateKey, Data(repeating: 3, count: 32))
        _ = try store.commitEdits(draft)
        XCTAssertEqual(try store.loadStoredEntryKeyMaterial()?.privateKey, Data(repeating: 9, count: 32))
        XCTAssertEqual(try store.loadStoredKeyMaterial()?.privateKey, Data(repeating: 3, count: 32))
    }

    func testRefusedSwapLeavesDraftUntouchedAndIdenticalMetadataStillTracksIdentity() throws {
        let full = try configuration()
        let split = try ChainedUpstreamConfiguration(endpointHost: "198.51.100.2", endpointPort: 51820,
            peerPublicKey: full.peerPublicKey, clientAddress: "10.64.0.6", allowedIPs: ["10.0.0.0/8"])
        let smallFull = try ChainedUpstreamConfiguration(endpointHost: full.endpointHost, endpointPort: 51820,
            peerPublicKey: full.peerPublicKey, clientAddress: full.clientAddress, allowedIPs: full.allowedIPs, interfaceMTU: 1280)
        var draft = try ChainedUpstreamEditDraft(id: "swap", generation: 1, configurations: [split, smallFull])
        XCTAssertThrowsError(try draft.swapOrder()) { XCTAssertEqual($0 as? WireGuardChainFailure, .entryMTUTooSmall) }
        XCTAssertEqual(draft.rows.map(\.configuration), [split, smallFull])
        XCTAssertEqual(draft.revision, 0)
        XCTAssertFalse(draft.hasChanges)
        var identical = try ChainedUpstreamEditDraft(id: "same", generation: 1, configurations: [full, full])
        try identical.swapOrder()
        XCTAssertTrue(identical.hasChanges, "Identical public metadata does not mean identical stored keys.")
        var single = try ChainedUpstreamEditDraft(id: "one", generation: 1, configurations: [full])
        XCTAssertThrowsError(try single.swapOrder())
    }

    func testPendingDeletionCannotDeleteANewerSavedGeneration() throws {
        let store = makeStore(FakeKeyItems())
        let original = try store.commit(rotation())
        let newer = try store.commit(rotation(host: "198.51.100.2"))
        XCTAssertThrowsError(try store.removeAll(expectedGeneration: original))
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.generation, newer)
        try store.removeAll(expectedGeneration: newer)
        XCTAssertNil(try store.loadStoredConfigurationRecord())
    }

    func testTwoHopAtomicSaveRenameRemoveAndStaleEditorFence() throws {
        let store = makeStore(FakeKeyItems())
        let first = try store.saveHop(index: 0, name: "Entry", replacement: rotation(), expectedGeneration: nil)
        let second = try store.saveHop(index: 1, name: "Exit", replacement: rotation(host: "198.51.100.2", key: Data(repeating: 9, count: 32)), expectedGeneration: first)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.orderedHops.map(\.displayName), ["Entry", "Exit"])
        XCTAssertEqual(try store.loadStoredEntryKeyMaterial()?.privateKey, try rotation().privateKey)
        XCTAssertEqual(try store.loadStoredKeyMaterial()?.privateKey, Data(repeating: 9, count: 32))
        XCTAssertThrowsError(try store.saveHop(index: 0, name: "Stale", replacement: nil, expectedGeneration: first))
        let renamed = try store.saveHop(index: 0, name: "New entry", replacement: nil, expectedGeneration: second)
        XCTAssertEqual(try store.loadStoredEntryKeyMaterial()?.privateKey, try rotation().privateKey)
        _ = try store.removeHop(index: 0, expectedGeneration: renamed)
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.orderedHops.map(\.displayName), ["Exit"])
        XCTAssertNil(try store.loadStoredEntryKeyMaterial())
        XCTAssertEqual(try store.loadStoredKeyMaterial()?.privateKey, Data(repeating: 9, count: 32))
    }

    func testMissingSingleHopKeyCanBeReplacedWithoutReadingTheOldSecret() throws {
        let keys = FakeKeyItems()
        let store = makeStore(keys)
        let generation = try store.saveHop(index: 0, name: "Old", replacement: rotation(), expectedGeneration: nil)
        try keys.delete(account: Naming.keyAccount(for: generation))
        XCTAssertNil(try store.loadStoredKeyMaterial())
        XCTAssertThrowsError(try store.saveHop(index: 0, name: "Rename", replacement: nil, expectedGeneration: generation))
        _ = try store.saveHop(index: 0, name: "Replaced", replacement: rotation(key: Data(repeating: 9, count: 32)), expectedGeneration: generation)
        XCTAssertEqual(try store.loadStoredKeyMaterial()?.privateKey, Data(repeating: 9, count: 32))
    }

    func testMissingChainSecretsCannotSilentlyDropAHopAndCanBeExplicitlyCleared() throws {
        let keys = FakeKeyItems()
        let store = makeStore(keys)
        let first = try store.saveHop(index: 0, name: "Entry", replacement: rotation(), expectedGeneration: nil)
        let second = try store.saveHop(index: 1, name: "Exit", replacement: rotation(host: "198.51.100.2"), expectedGeneration: first)
        try keys.delete(account: Naming.keyAccount(for: second))
        XCTAssertThrowsError(try store.removeHop(index: 0, expectedGeneration: second))
        XCTAssertThrowsError(try store.saveHop(index: 0, name: "New entry", replacement: rotation(), expectedGeneration: second))
        XCTAssertEqual(try store.loadStoredConfigurationRecord()?.configuration.orderedHops.count, 2)
        try store.removeAll()
        XCTAssertNil(try store.loadStoredConfigurationRecord())
        XCTAssertTrue(keys.storedAccounts.isEmpty)
    }

    func testEntryCredentialReadRetriesLockedStorageButRefusesMissingSecrets() throws {
        let keys = FakeKeyItems()
        let store = makeStore(keys)
        let first = try store.saveHop(index: 0, name: "Entry", replacement: rotation(), expectedGeneration: nil)
        let generation = try store.saveHop(index: 1, name: "Exit", replacement: rotation(), expectedGeneration: first)
        let config = try XCTUnwrap(store.loadStoredConfigurationRecord()?.configuration)
        let credentials = try ChainedSessionCredentialReader.readEntry(store: store, latchedConfiguration: config)
        XCTAssertEqual(credentials.generation, generation)
        credentials.scrubSecrets()
        keys.loadFailure = Failure.keychainRefused(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try ChainedSessionCredentialReader.readEntry(store: store, latchedConfiguration: config)) {
            XCTAssertEqual($0 as? ChainedSessionBuildFailure, .credentialsUnavailable)
        }
        keys.loadFailure = nil
        try keys.delete(account: Naming.keyAccount(for: generation))
        XCTAssertThrowsError(try ChainedSessionCredentialReader.readEntry(store: store, latchedConfiguration: config)) {
            XCTAssertEqual($0 as? ChainedSessionCredentialRefusal, .upstreamNoLongerReady(.noPrivateKeyStored))
        }
    }

    func testBinaryChainCodecPreservesBothOptionalPSKsAndRejectsDamage() throws {
        for entryPSK in [nil, Data(repeating: 7, count: 32)] {
            for exitPSK in [nil, Data(repeating: 8, count: 32)] {
                let encoded = ChainedUpstreamKeyItemCodec.encodeChain(
                    exit: (Data(repeating: 3, count: 32), exitPSK), entry: (Data(repeating: 4, count: 32), entryPSK))
                let decoded = try XCTUnwrap(ChainedUpstreamKeyItemCodec.decodeChain(encoded))
                XCTAssertEqual(decoded.exit.privateKey, Data(repeating: 3, count: 32))
                XCTAssertEqual(decoded.entry.privateKey, Data(repeating: 4, count: 32))
                XCTAssertEqual(decoded.exit.presharedKey, exitPSK)
                XCTAssertEqual(decoded.entry.presharedKey, entryPSK)
                XCTAssertLessThanOrEqual(encoded.count, 135)
                XCTAssertNil(ChainedUpstreamKeyItemCodec.decodeChain(Data(encoded.dropLast())))
                var badFlag = encoded; badFlag[37] = 3
                XCTAssertNil(ChainedUpstreamKeyItemCodec.decodeChain(badFlag))
            }
        }
    }

    private func configuration(
        host: String = "203.0.113.9",
        peerPublicKey: String = Data(1...32).base64EncodedString()
    ) throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: host, endpointPort: 51820, peerPublicKey: peerPublicKey,
            clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
            persistentKeepaliveSeconds: 25, dnsAddresses: ["10.64.0.1"])
    }

    private func rotation(
        host: String = "203.0.113.9",
        key: Data = Data((1...32).map { UInt8($0) }),
        presharedKey: Data? = nil
    ) throws -> ChainedUpstreamRotation {
        try ChainedUpstreamRotation(
            configuration: try configuration(host: host), privateKey: key,
            presharedKey: presharedKey)
    }

    private func makeStore(
        _ keyItems: FakeKeyItems,
        generations: [UInt64] = [],
        identity: ChainedUpstreamStoreIdentity = .production
    ) -> ChainedUpstreamKeychainStore {
        guard !generations.isEmpty else {
            return ChainedUpstreamKeychainStore(
                containerURL: container, identity: identity, keyItems: keyItems)
        }
        let box = GenerationBox(generations)
        return ChainedUpstreamKeychainStore(
            containerURL: container, identity: identity, keyItems: keyItems,
            mint: ChainedUpstreamGenerationMint { _ in
                guard let next = box.take() else { throw Failure.entropyUnavailable }
                return Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: next >> (8 * $0)) })
            })
    }

    private final class GenerationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64]
        init(_ values: [UInt64]) { self.values = values }
        func take() -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            return values.isEmpty ? nil : values.removeFirst()
        }
    }

    private func writeRawConfiguration(_ json: String) throws {
        try Data(json.utf8).write(
            to: container.appendingPathComponent(Naming.configurationFilename(for: .production)),
            options: .atomic)
    }

    /// Runs `body` with the writer lock file present but impossible to open, which is what
    /// `FilterPublishLock.openLockDescriptor` returning `nil` looks like in the field.
    ///
    /// The staging is ASSERTED, not assumed: a user for whom mode bits do not apply would
    /// take the LOCKED path instead and every test built on this would pass while proving
    /// nothing about the degrade path it exists to cover.
    private func withUnavailableWriterLock(_ body: () throws -> Void) throws {
        let url = container.appendingPathComponent(Naming.writeLockFilename(for: .production))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let descriptor = FilterPublishLock.openLockDescriptor(at: url) {
            close(descriptor)
            throw XCTSkip("this user can open a 000-mode file; the fixture cannot be staged")
        }
        try body()
    }

    // MARK: - The happy path, through the reader that will actually consume it

    func testACommittedRotationIsReadBackAsAConsistentPair() throws {
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems)
        let key = Data((1...32).map { UInt8($0) })
        let generation = try store.commit(try rotation(key: key))

        XCTAssertNotEqual(generation, 0)
        guard case .ready(let ready) = ChainedUpstreamReadiness.evaluate(store: store) else {
            return XCTFail("a committed rotation must be ready")
        }
        XCTAssertEqual(ready.configuration.endpointHost, "203.0.113.9")
        XCTAssertEqual(ready.privateKey, key)
    }

    func testSaveDateTravelsWithTheCommittedRotation() throws {
        let keys = FakeKeyItems()
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(90)
        let first = ChainedUpstreamKeychainStore(
            containerURL: container, identity: .production, keyItems: keys, now: { firstDate })
        let second = ChainedUpstreamKeychainStore(
            containerURL: container, identity: .production, keyItems: keys, now: { secondDate })
        let generation = try first.commit(try rotation())
        let initial = try XCTUnwrap(second.loadStoredConfigurationRecord())
        XCTAssertEqual(initial.generation, generation)
        XCTAssertEqual(initial.savedAt, firstDate)

        // A refused replacement must not move the date ahead of the saved configuration.
        keys.addFailure = Failure.entropyUnavailable
        XCTAssertThrowsError(try second.commit(try rotation(host: "203.0.113.10")))
        XCTAssertEqual(try first.loadStoredConfigurationRecord()?.savedAt, firstDate)
        XCTAssertEqual(try first.loadStoredConfigurationRecord()?.generation, generation)
        keys.addFailure = nil

        let replacedGeneration = try second.commit(try rotation(host: "203.0.113.10"))
        let replacement = try XCTUnwrap(first.loadStoredConfigurationRecord())
        XCTAssertEqual(replacement.savedAt, secondDate)
        XCTAssertEqual(replacement.generation, replacedGeneration)
        XCTAssertEqual(replacement.configuration.endpointHost, "203.0.113.10")

        try first.removeAll()
        XCTAssertNil(try second.loadStoredConfigurationRecord())
    }

    func testLegacySavedConfigurationRemainsReadableWithoutInventingADate() throws {
        let keys = FakeKeyItems()
        // Stay exactly representable even on Foundation versions that route JSON numbers
        // through Double: this fixture tests missing metadata, not integer-parser precision.
        let store = makeStore(keys, generations: [11])
        let generation = try store.commit(try rotation())
        let url = container.appendingPathComponent(Naming.configurationFilename(for: .production))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        envelope.removeValue(forKey: "savedAt")
        try JSONSerialization.data(withJSONObject: envelope).write(to: url, options: .atomic)

        let record = try XCTUnwrap(store.loadStoredConfigurationRecord())
        XCTAssertNil(record.savedAt)
        XCTAssertEqual(record.generation, generation)
        guard case .ready = ChainedUpstreamReadiness.evaluate(store: store) else {
            return XCTFail("Adding metadata must not invalidate a configuration from an older build")
        }
    }

    // MARK: - The pre-shared key rides in the same secret item

    func testAPreSharedKeyRoundTripsThroughTheKeyItem() throws {
        // A rotation carrying a PSK must persist it alongside the private key in ONE item and
        // read it back intact — both the store-level `loadStoredKeyMaterial` and the readiness
        // path the tunnel actually uses.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems)
        let key = Data((1...32).map { UInt8($0) })
        let psk = Data(repeating: 0xAB, count: 32)
        try store.commit(try rotation(key: key, presharedKey: psk))

        let material = try store.loadStoredKeyMaterial()
        XCTAssertEqual(material?.privateKey, key)
        XCTAssertEqual(material?.presharedKey, psk, "the PSK must survive the key-item round trip")

        guard case .ready(let ready) = ChainedUpstreamReadiness.evaluate(store: store) else {
            return XCTFail("a committed PSK-bearing rotation must be ready")
        }
        XCTAssertEqual(ready.presharedKey, psk)
    }

    func testARotationWithoutAPreSharedKeyReadsBackAsNil() throws {
        // The common case: no PSK persists as no PSK. A second rotation over a PSK-bearing one
        // must also clear it, so the two are exercised on one store.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11, 22])
        try store.commit(try rotation(presharedKey: Data(repeating: 0xAB, count: 32)))
        XCTAssertNotNil(try store.loadStoredKeyMaterial()?.presharedKey)

        try store.commit(try rotation(host: "198.51.100.4"))  // no PSK
        XCTAssertNil(
            try store.loadStoredKeyMaterial()?.presharedKey,
            "rotating to a no-PSK configuration must clear the PSK")
        guard case .ready(let ready) = ChainedUpstreamReadiness.evaluate(store: store) else {
            return XCTFail("a committed no-PSK rotation must be ready")
        }
        XCTAssertNil(ready.presharedKey)
    }

    func testALegacyBareKeyItemDecodesToANilPreSharedKey() throws {
        // BACKWARD COMPATIBILITY: a value written before PSK support is a bare 32-byte private
        // key with no presence flag. It MUST decode to a nil PSK rather than fail, or an install
        // that rotated under the old format reports its key unreadable across the update. The
        // legacy value is written straight into the backend to bypass the new-format encoder.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        let legacyKey = Data((1...32).map { UInt8($0) })
        try store.commit(try rotation(key: legacyKey))  // config at gen 11, new-format key item
        try keyItems.delete(account: Naming.keyAccount(for: 11))
        try keyItems.add(legacyKey, account: Naming.keyAccount(for: 11))  // 32 bytes, old format

        let material = try store.loadStoredKeyMaterial()
        XCTAssertEqual(material?.privateKey, legacyKey, "the legacy 32-byte value is the key")
        XCTAssertNil(material?.presharedKey, "a pre-PSK bare key must decode to a nil PSK")
        guard case .ready(let ready) = ChainedUpstreamReadiness.evaluate(store: store) else {
            return XCTFail("a legacy no-PSK key item must still be ready")
        }
        XCTAssertNil(ready.presharedKey)
    }

    func testTheCodecHandsAnUnrecognisedLayoutBackWholeWithNoPreSharedKey() throws {
        // The security property the codec's doc comment states: decode() NEVER fabricates a
        // 32-byte prefix from a value it does not recognise. A prefix would hand the engine a
        // truncated private key AND silently drop whatever followed — a live key aimed at the
        // wrong peer with no PSK, which no length check downstream could catch because 32 bytes
        // is a valid key length. Each case is a raw key-item value the encoder never produces;
        // all must come back WHOLE, with a nil PSK, so readiness refuses them on length.
        let key: [UInt8] = (1...32).map { UInt8($0) }
        let cases: [(name: String, value: Data)] = [
            ("33 bytes, unknown flag 0x02", Data(key + [0x02])),
            ("33 bytes, flag 0x01 claims a PSK with no bytes", Data(key + [0x01])),
            ("65 bytes, flag 0x00 with trailing bytes", Data(key + [0x00] + Array(repeating: 0xCD, count: 32))),
            ("40 bytes, a length in no branch", Data(Array(repeating: 0xEE, count: 40))),
        ]
        for testCase in cases {
            let decoded = ChainedUpstreamKeyItemCodec.decode(testCase.value)
            XCTAssertEqual(
                decoded.privateKey, testCase.value,
                "\(testCase.name): the WHOLE value must come back as the private key")
            XCTAssertEqual(
                decoded.privateKey.count, testCase.value.count,
                "\(testCase.name): NOT a 32-byte prefix — a truncated key would mis-pair")
            XCTAssertNil(
                decoded.presharedKey, "\(testCase.name): an unrecognised layout carries no PSK")
        }
    }

    func testAMalformedKeyItemValueRefusesAsMalformedPrivateKeyThroughReadiness() throws {
        // The fail-closed CONSEQUENCE of the whole-value contract above, end to end: a
        // malformed key item is not a 32-byte key, so readiness refuses it as
        // `.malformedPrivateKey` rather than building a session from a truncated key. 40 bytes
        // is a length no codec branch recognises; the raw value is written straight into the
        // backend, bypassing the encoder.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())  // config + key at gen 11
        try keyItems.delete(account: Naming.keyAccount(for: 11))
        try keyItems.add(Data(repeating: 0xEE, count: 40), account: Naming.keyAccount(for: 11))

        XCTAssertEqual(
            ChainedUpstreamReadiness.evaluate(store: store), .notReady(.malformedPrivateKey),
            "a key item that is not 32 bytes must fail closed, never yield a truncated key")
    }

    func testNothingStoredIsAbsentRatherThanAnError() throws {
        let store = makeStore(FakeKeyItems())
        XCTAssertNil(try store.loadStoredConfiguration())
        XCTAssertNil(try store.loadStoredPrivateKey())
        XCTAssertEqual(
            ChainedUpstreamReadiness.evaluate(store: store), .notReady(.noConfigurationStored))
    }

    func testTwoRotationsNeverShareAGeneration() throws {
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems)
        let first = try store.commit(try rotation(host: "203.0.113.9"))
        let second = try store.commit(try rotation(host: "198.51.100.4"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.loadStoredConfiguration()?.1, second)
        XCTAssertEqual(keyItems.storedAccounts, [Naming.keyAccount(for: second)])
    }

    // MARK: - Interruption: every crash point leaves a consistent pair

    func testARotationKilledAfterTheKeyAddLeavesThePreviousPairUntouched() throws {
        // Step 1 is ADDITIVE, so the currently committed pair is not disturbed by a rotation
        // that never reaches its commit point. The rotation simply did not happen.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11, 22])
        try store.commit(try rotation(host: "203.0.113.9"))

        try store.addKeyItem(Data(repeating: 0x5A, count: 32), at: 22)  // killed here

        XCTAssertEqual(try store.loadStoredConfiguration()?.1, 11)
        XCTAssertEqual(try store.loadStoredPrivateKey()?.1, 11)
        XCTAssertEqual(try store.loadStoredPrivateKey()?.0, Data((1...32).map { UInt8($0) }))
        guard case .ready(let ready) = ChainedUpstreamReadiness.evaluate(store: store) else {
            return XCTFail("the previous pair must still be usable")
        }
        XCTAssertEqual(ready.configuration.endpointHost, "203.0.113.9")
    }

    func testARotationKilledAfterTheCommitPointIsCompleteAndLeavesOnlyAnOrphan() throws {
        // Step 2 is the sole commit point: one atomic replace. A reader sees the old inode or
        // the new one, never a splice, and the un-swept old key is harmless because no
        // configuration names it.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11, 22])
        try store.commit(try rotation(host: "203.0.113.9"))

        let newKey = Data(repeating: 0x5A, count: 32)
        try store.addKeyItem(newKey, at: 22)
        try store.commitConfiguration(try configuration(host: "198.51.100.4"), at: 22)
        // killed before the sweep

        XCTAssertEqual(try store.loadStoredConfiguration()?.1, 22)
        XCTAssertEqual(try store.loadStoredPrivateKey()?.0, newKey)
        XCTAssertEqual(
            keyItems.storedAccounts,
            [Naming.keyAccount(for: 11), Naming.keyAccount(for: 22)].sorted())
        guard case .ready(let ready) = ChainedUpstreamReadiness.evaluate(store: store) else {
            return XCTFail("the new pair must be consistent")
        }
        XCTAssertEqual(ready.configuration.endpointHost, "198.51.100.4")
    }

    func testAFailedKeyAddCommitsNothing() throws {
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11, 22])
        try store.commit(try rotation(host: "203.0.113.9"))

        keyItems.addFailure = Failure.keychainRefused(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.commit(try rotation(host: "198.51.100.4")))

        XCTAssertEqual(try store.loadStoredConfiguration()?.0.endpointHost, "203.0.113.9")
        XCTAssertEqual(try store.loadStoredConfiguration()?.1, 11)
    }

    func testAKeyAddNeverReplacesAnExistingGeneration() throws {
        // The commit protocol depends on additivity: an upsert at a colliding account would
        // replace a secret the live configuration still names.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())
        XCTAssertThrowsError(try store.addKeyItem(Data(repeating: 0xFF, count: 32), at: 11))
        XCTAssertEqual(try store.loadStoredPrivateKey()?.0, Data((1...32).map { UInt8($0) }))
    }

    // MARK: - The sweep

    func testASweepDeletesEveryOrphanAndKeepsTheCommittedKey() throws {
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())
        try store.addKeyItem(Data(repeating: 0x01, count: 32), at: 7)
        try store.addKeyItem(Data(repeating: 0x02, count: 32), at: 8)

        try store.sweepOrphanedKeys()

        XCTAssertEqual(keyItems.storedAccounts, [Naming.keyAccount(for: 11)])
        XCTAssertNotNil(try store.loadStoredPrivateKey())
    }

    func testAFailedConfigurationCommitDoesNotStrandTheKeyItem() throws {
        // A Keychain item outlives the app's CONTAINER — it survives deleting the app — so a
        // key added for a rotation that then failed to commit is not garbage, it is key
        // material left on the device after the save was reported as failed.
        //
        // The launch sweep is no backstop on the FIRST save: with no committed configuration
        // it deliberately does nothing, because it has no generation to preserve and cannot
        // tell an orphan from the key of a rotation about to commit. So the very first thing a
        // user ever stores here is exactly the case that would persist indefinitely.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [0x11])

        // The container becomes unwritable AFTER the key is staged, which is the only window
        // that can strand one. Blocking it up front instead fails the committed-generation
        // READ, so the key is never added and the test passes without the cleanup existing —
        // that is what the first version of this test did, and the mutation caught it.
        let configuration = container.appendingPathComponent(
            ChainedUpstreamSecretNaming.configurationFilename(for: .production))
        keyItems.afterAdd = {
            try? FileManager.default.createDirectory(
                at: configuration, withIntermediateDirectories: true)
        }

        XCTAssertThrowsError(try store.commit(rotation())) { error in
            XCTAssertFalse(
                error is ChainedUpstreamSecretStoreFailure
                    && "\(error)".contains("writerExclusionUnavailable"),
                "the lock failed instead of the commit — this does not exercise the path")
        }

        XCTAssertEqual(
            try keyItems.accounts(), [],
            "a rotation whose commit failed left its private key in the Keychain, where it "
                + "outlives even deleting the app")
    }

    func testASweepThatRacesARotationDeletesNothing() throws {
        // The interleave that would delete the LIVE key: a launch sweep reads the committed
        // generation, a rotation commits and sweeps, and the launch sweep then deletes
        // "everything except" a generation that is no longer committed. The result — a
        // configuration with no key at a STABLE generation — is reported as
        // `.noPrivateKeyStored` forever and is indistinguishable from the migrated-device flow
        // it would be diagnosed as.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation(host: "203.0.113.9"))

        // A second writer commits generation 22 while this sweep is enumerating.
        let newKey = Data(repeating: 0x5A, count: 32)
        try keyItems.add(newKey, account: Naming.keyAccount(for: 22))
        let raced = UnsafeSendableBox(store: store, configuration: try configuration(host: "198.51.100.4"))
        keyItems.beforeEnumeration = { raced.commitAtTwentyTwo() }

        try store.sweepOrphanedKeys()

        XCTAssertEqual(try store.loadStoredConfiguration()?.1, 22)
        XCTAssertEqual(
            try store.loadStoredPrivateKey()?.0, newKey,
            "the sweep must not delete a key committed after it read its target")
        XCTAssertTrue(ChainedUpstreamReadiness.evaluate(store: store).isReady)
    }

    private final class UnsafeSendableBox: @unchecked Sendable {
        private let store: ChainedUpstreamKeychainStore
        private let configuration: ChainedUpstreamConfiguration
        init(store: ChainedUpstreamKeychainStore, configuration: ChainedUpstreamConfiguration) {
            self.store = store
            self.configuration = configuration
        }
        func commitAtTwentyTwo() { try? store.commitConfiguration(configuration, at: 22) }
    }

    // MARK: - Writer exclusion is a requirement, not an optimization

    func testASweepRefusesRatherThanRunningWithoutWriterExclusion() throws {
        // The interleave `testASweepThatRacesARotationDeletesNothing` does NOT cover, staged
        // end to end. A concurrent rotation has additively added its key at 22 and has not yet
        // reached its commit point. This pass reads 11, enumerates, rechecks 11 — and the
        // rotation's `rename(2)` lands in the gap BEFORE the deletes. The orphan list was
        // computed against 11, so the pass deletes the key generation 22 has just committed
        // and leaves a configuration whose key is gone at a STABLE generation: durable, and
        // reported as `noPrivateKeyStored` for the life of the install.
        //
        // Nothing inside the sweep can close that gap — a second recheck only moves it — so
        // the fix is the refusal: with exclusion unavailable the pass throws, having deleted
        // nothing. Before that, `FilterPublishLock.withExclusiveLock` ran this body UNLOCKED
        // whenever the lock file could not be opened.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation(host: "203.0.113.9"))
        let newKey = Data(repeating: 0x5A, count: 32)
        try keyItems.add(newKey, account: Naming.keyAccount(for: 22))
        let raced = UnsafeSendableBox(
            store: store, configuration: try configuration(host: "198.51.100.4"))
        keyItems.beforeDelete = { raced.commitAtTwentyTwo() }

        try withUnavailableWriterLock {
            XCTAssertThrowsError(try store.sweepOrphanedKeys()) {
                XCTAssertEqual($0 as? Failure, .writerExclusionUnavailable)
            }
        }

        XCTAssertEqual(
            keyItems.storedAccounts,
            [Naming.keyAccount(for: 11), Naming.keyAccount(for: 22)].sorted(),
            "a sweep that cannot exclude a concurrent writer must delete nothing")
        XCTAssertTrue(
            ChainedUpstreamReadiness.evaluate(store: store).isReady,
            "the committed pair must survive a refused sweep")
    }

    func testACommitRefusesRatherThanWritingWithoutWriterExclusion() throws {
        // Refused as an ordinary store failure, not a crash: `writerExclusionUnavailable` is a
        // `ChainedUpstreamSecretStoreFailure` like every other reason a write can fail, so the
        // call sites that already handle `keychainRefused` and `configurationUnreadable` need
        // no new shape. `commit`'s contract — a throw commits NOTHING — still holds, and holds
        // more simply than before: the refusal precedes even the additive key add.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])

        try withUnavailableWriterLock {
            XCTAssertThrowsError(try store.commit(try rotation())) {
                XCTAssertEqual($0 as? Failure, .writerExclusionUnavailable)
            }
        }

        XCTAssertEqual(keyItems.storedAccounts, [], "no half may land without exclusion")
        XCTAssertNil(try store.loadStoredConfiguration())
    }

    func testRemoveAllRefusesRatherThanDeletingWithoutWriterExclusion() throws {
        // "Delete my key" is strict, and strict includes the exclusion: an unserialized
        // removal that interleaves a commit deletes the key the commit just landed and leaves
        // the configuration it landed with. Reporting a failure the user can retry is the only
        // honest outcome — the pair is still intact and still deletable.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())

        try withUnavailableWriterLock {
            XCTAssertThrowsError(try store.removeAll()) {
                XCTAssertEqual($0 as? Failure, .writerExclusionUnavailable)
            }
        }

        XCTAssertEqual(keyItems.storedAccounts, [Naming.keyAccount(for: 11)])
        XCTAssertNotNil(try store.loadStoredConfiguration())
    }

    // MARK: - The QA identity and the production identity share a container

    func testAQABuildAndAProductionBuildDoNotShareOneUpstreamRecord() throws {
        // ONE container, because `group.com.lavasec` is not config-scoped: the App Group
        // entitlement is identical in both builds and they install side by side, their bundle
        // IDs being the only thing that differs. The key halves ARE separated, by the
        // config-scoped access group — modelled here as two backends, which is exactly what
        // two access groups are to this store.
        //
        // With one shared `chained-upstream.json`, the QA rotation below replaced the
        // generation the production build had committed while its key stayed in the QA-only
        // group, so the production build then looked up `upstream-key/<QA generation>` in a
        // group that does not hold it and reported `noPrivateKeyStored` — "re-enter your key"
        // — until reconfigured.
        let productionItems = FakeKeyItems()
        let qaItems = FakeKeyItems()
        let production = makeStore(productionItems, generations: [11], identity: .production)
        let qa = makeStore(qaItems, generations: [22], identity: .qa)

        try production.commit(try rotation(host: "203.0.113.9"))
        try qa.commit(try rotation(host: "198.51.100.4", key: Data(repeating: 0x5A, count: 32)))

        XCTAssertEqual(try production.loadStoredConfiguration()?.0.endpointHost, "203.0.113.9")
        XCTAssertEqual(try production.loadStoredConfiguration()?.1, 11)
        XCTAssertEqual(try qa.loadStoredConfiguration()?.0.endpointHost, "198.51.100.4")
        XCTAssertEqual(try qa.loadStoredConfiguration()?.1, 22)
        guard case .ready(let ready) = ChainedUpstreamReadiness.evaluate(store: production) else {
            return XCTFail("a QA rotation must not strand the production build without a key")
        }
        XCTAssertEqual(ready.configuration.endpointHost, "203.0.113.9")
        XCTAssertTrue(ChainedUpstreamReadiness.evaluate(store: qa).isReady)
    }

    func testTheTwoIdentitiesDoNotShareAWriterLockedRegion() throws {
        // The lock is namespaced with the file it guards, so this is really a pin on that
        // pairing: a QA writer holding the production lock would serialize two builds that
        // touch disjoint files, and — the shape that actually matters — a per-identity lock
        // over a SHARED file would serialize nothing at all.
        let store = makeStore(FakeKeyItems(), generations: [11], identity: .qa)
        try store.commit(try rotation())

        let productionLock = container.appendingPathComponent(
            Naming.writeLockFilename(for: .production))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: productionLock.path),
            "a QA write must not touch the production lock file")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent(Naming.writeLockFilename(for: .qa)).path))
    }

    func testASweepWithNoCommittedConfigurationDeletesNothing() throws {
        // What a killed FIRST rotation leaves. "Delete everything except the committed
        // generation" with nothing committed means "delete everything", which would destroy a
        // key the very next commit could have adopted — and `removeAll` is the only operation
        // entitled to clear key material.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems)
        try store.addKeyItem(Data(repeating: 0x01, count: 32), at: 7)

        try store.sweepOrphanedKeys()

        XCTAssertEqual(keyItems.storedAccounts, [Naming.keyAccount(for: 7)])
    }

    func testASweepOverAnUnreadableConfigurationDeletesNothing() throws {
        // INV-PERSIST-1: unreadable is never absent. Collapsing the two here would delete a
        // WireGuard private key that has no sync copy and no backup copy, because the device
        // happened to be locked.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())
        try store.addKeyItem(Data(repeating: 0x01, count: 32), at: 7)
        try withUnreadableConfiguration {
            XCTAssertThrowsError(try store.sweepOrphanedKeys())
        }
        XCTAssertEqual(
            keyItems.storedAccounts,
            [Naming.keyAccount(for: 7), Naming.keyAccount(for: 11)].sorted())
    }

    // MARK: - Removal

    func testRemoveAllDeletesEveryGenerationNotJustTheCommittedOne() throws {
        // Keychain items outlive app deletion, so an orphan left behind is a live private key
        // with no owner. "Delete my key" is not a best-effort operation.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())
        try store.addKeyItem(Data(repeating: 0x01, count: 32), at: 7)
        try store.addKeyItem(Data(repeating: 0x02, count: 32), at: 8)

        try store.removeAll()

        XCTAssertEqual(keyItems.storedAccounts, [])
        XCTAssertNil(try store.loadStoredConfiguration())
        XCTAssertEqual(
            ChainedUpstreamReadiness.evaluate(store: store), .notReady(.noConfigurationStored))
    }

    func testRemoveAllOnAnEmptyStoreIsNotAnError() throws {
        XCTAssertNoThrow(try makeStore(FakeKeyItems()).removeAll())
    }

    // MARK: - A locked device is not a preference (INV-PERSIST-1)

    func testAnUnreadableConfigurationThrowsRatherThanReportingNothingStored() throws {
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())

        try withUnreadableConfiguration {
            XCTAssertThrowsError(try store.loadStoredConfiguration()) { error in
                guard case .configurationUnreadable = error as? Failure else {
                    return XCTFail("expected configurationUnreadable, got \(error)")
                }
            }
            XCTAssertThrowsError(try store.loadStoredPrivateKey())
            XCTAssertEqual(
                ChainedUpstreamReadiness.evaluate(store: store), .notReady(.storeUnavailable),
                "a locked device must not read as a preference")
        }
    }

    func testTheUnreadableBreadcrumbCarriesNoFilesystemPath() throws {
        let store = makeStore(FakeKeyItems(), generations: [11])
        try store.commit(try rotation())
        try withUnreadableConfiguration {
            do {
                _ = try store.loadStoredConfiguration()
                XCTFail("expected a throw")
            } catch Failure.configurationUnreadable(let description) {
                XCTAssertFalse(description.contains("/"))
                XCTAssertFalse(description.contains(Naming.configurationFilename(for: .production)))
            }
        }
    }

    /// Runs `body` with the configuration file present but unreadable.
    ///
    /// chmod-000, which is what the suite can reproduce: it exercises the CLASSIFICATION, not
    /// Data-Protection locking, which no host test can reproduce (the caveat
    /// `SharedStateFileReader` already records). Skipped when the test runs as a user for whom
    /// permissions do not apply, rather than passing vacuously.
    private func withUnreadableConfiguration(_ body: () throws -> Void) throws {
        let url = container.appendingPathComponent(Naming.configurationFilename(for: .production))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard (try? Data(contentsOf: url)) == nil else {
            throw XCTSkip("this user can read a 000-mode file; the fixture cannot be staged")
        }
        try body()
    }

    // MARK: - Unusable is not unreadable

    func testAConfigurationTheValidatorNoLongerAcceptsIsUnusableNotUnreadable() throws {
        // Reachable WITHOUT corruption: `ChainedUpstreamConfiguration.init(from:)` revalidates
        // on every decode and the validator has tightened twice already, so an app update can
        // turn a value that was valid when written into one that no longer decodes. Reporting
        // that as `storeUnavailable` would describe a permanent wedge as a locked device and
        // leave the user no path out.
        let store = makeStore(FakeKeyItems())
        try writeRawConfiguration(
            """
            {"schema":1,"generation":11,"configuration":{"allowedIPs":["0.0.0.0/0"],\
            "clientAddress":"10.64.0.5","endpointHost":"203.0.113.9","endpointPort":51820,\
            "peerPublicKey":"\(Data(repeating: 0, count: 32).base64EncodedString())",\
            "persistentKeepaliveSeconds":25}}
            """)
        XCTAssertThrowsError(try store.loadStoredConfiguration()) {
            XCTAssertEqual($0 as? Failure, .configurationUnusable)
        }
    }

    func testAZeroGenerationIsRefusedRatherThanMatched() throws {
        // `0` is the value a defaulted or zero-filled decode produces. Accepting it would let
        // two damaged halves both read `0` and compare equal.
        let store = makeStore(FakeKeyItems())
        try writeRawConfiguration(
            """
            {"schema":1,"generation":0,"configuration":{"allowedIPs":["0.0.0.0/0"],\
            "clientAddress":"10.64.0.5","endpointHost":"203.0.113.9","endpointPort":51820,\
            "peerPublicKey":"\(Data(1...32).base64EncodedString())",\
            "persistentKeepaliveSeconds":25}}
            """)
        XCTAssertThrowsError(try store.loadStoredConfiguration()) {
            XCTAssertEqual($0 as? Failure, .configurationUnusable)
        }
    }

    func testAnUnknownSchemaIsUnusableRatherThanSilentlyAdopted() throws {
        let store = makeStore(FakeKeyItems())
        try writeRawConfiguration(
            """
            {"schema":99,"generation":11,"configuration":{"allowedIPs":["0.0.0.0/0"],\
            "clientAddress":"10.64.0.5","endpointHost":"203.0.113.9","endpointPort":51820,\
            "peerPublicKey":"\(Data(1...32).base64EncodedString())",\
            "persistentKeepaliveSeconds":25}}
            """)
        XCTAssertThrowsError(try store.loadStoredConfiguration()) {
            XCTAssertEqual($0 as? Failure, .configurationUnusable)
        }
    }

    func testAnUnusableConfigurationCanStillBeRotatedOver() throws {
        // The recovery from the wedge above. A rotation over an UNREADABLE configuration is
        // refused by the writer fence; over an unusable one it must be allowed, or the user
        // can never replace it.
        let store = makeStore(FakeKeyItems(), generations: [11])
        try writeRawConfiguration("{\"schema\":99,\"generation\":11}")
        XCTAssertNoThrow(try store.commit(try rotation()))
        XCTAssertEqual(try store.loadStoredConfiguration()?.1, 11)
    }

    func testTheWriterRefusesToReplaceAnUnreadableConfiguration() throws {
        // INV-PERSIST-1's writer fence: replacing a file you cannot read means you cannot know
        // what you are destroying, and here the thing being destroyed is the only pointer to a
        // key with no backup and no sync copy.
        let store = makeStore(FakeKeyItems(), generations: [11, 22])
        try store.commit(try rotation(host: "203.0.113.9"))
        try withUnreadableConfiguration {
            XCTAssertThrowsError(try store.commitConfiguration(try configuration(host: "198.51.100.4"), at: 22))
        }
        XCTAssertEqual(try store.loadStoredConfiguration()?.0.endpointHost, "203.0.113.9")
    }

    // MARK: - The state a single-record store could not express

    func testAConfigurationWhoseKeyIsGoneIsDistinctFromNothingStored() throws {
        // A migrated device: the app-group file travels, the `ThisDeviceOnly` key does not.
        // The refusal has to be `noPrivateKeyStored` (re-enter your key), not
        // `noConfigurationStored` (set the feature up), and a store keeping both halves in ONE
        // Keychain item could not tell them apart at all.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())
        try keyItems.delete(account: Naming.keyAccount(for: 11))

        XCTAssertNil(try store.loadStoredPrivateKey())
        XCTAssertNotNil(try store.loadStoredConfiguration())
        XCTAssertEqual(
            ChainedUpstreamReadiness.evaluate(store: store), .notReady(.noPrivateKeyStored))
    }

    // MARK: - The generation binds the two halves (plan constraint C6)

    func testTheKeyIsFetchedUnderTheCommittedGenerationSoTheHalvesCannotDisagree() throws {
        // C6 asks that one rotation stamp the SAME value on both halves. The key item is
        // ADDRESSED by generation, so the account name is the stamp and there is no second
        // value that could carry a different one: a key stored at a generation the
        // configuration does not name is simply not found.
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())

        try keyItems.delete(account: Naming.keyAccount(for: 11))
        try keyItems.add(Data(repeating: 0xEE, count: 32), account: Naming.keyAccount(for: 12))

        XCTAssertNil(
            try store.loadStoredPrivateKey(),
            "a key at an uncommitted generation must not be adopted by the committed configuration")
        XCTAssertEqual(
            ChainedUpstreamReadiness.evaluate(store: store), .notReady(.noPrivateKeyStored))
    }

    func testEveryReadReportsTheGenerationItsHalfWasFetchedAt() throws {
        let keyItems = FakeKeyItems()
        let store = makeStore(keyItems, generations: [11])
        try store.commit(try rotation())
        XCTAssertEqual(try store.loadStoredConfiguration()?.1, 11)
        XCTAssertEqual(try store.loadStoredPrivateKey()?.1, 11)
        // Through the protocol the tunnel actually uses. The key read now carries the PSK too,
        // so the generation is the third element.
        XCTAssertEqual(try store.loadConfiguration()?.1, ChainedUpstreamStoreGeneration(11))
        XCTAssertEqual(try store.loadPrivateKey()?.generation, ChainedUpstreamStoreGeneration(11))
    }
}
