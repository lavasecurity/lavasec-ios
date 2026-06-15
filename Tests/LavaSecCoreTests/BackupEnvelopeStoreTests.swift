import XCTest
@testable import LavaSecCore

final class BackupEnvelopeStoreTests: XCTestCase {
    private final class InMemoryBackupEnvelopeStorage: BackupEnvelopeStorage, @unchecked Sendable {
        private(set) var data: [String: Data] = [:]
        private(set) var dates: [String: Date] = [:]
        private(set) var removedKeys: [String] = []

        func data(forKey key: String) -> Data? { data[key] }
        func date(forKey key: String) -> Date? { dates[key] }
        func set(_ value: Data, forKey key: String) { data[key] = value }
        func set(_ value: Date, forKey key: String) { dates[key] = value }
        func removeObject(forKey key: String) {
            data[key] = nil
            dates[key] = nil
            removedKeys.append(key)
        }
    }

    private func makeEnvelope(ciphertextByteSize: Int = 4_096) -> ZeroKnowledgeBackupEnvelope {
        ZeroKnowledgeBackupEnvelope(
            payloadCiphertext: "Y2lwaGVydGV4dA==",
            keySlots: [],
            ciphertextByteSize: ciphertextByteSize,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testStorageKeysMatchLegacyDefaultsKeys() {
        // These literal keys are load-bearing: a rename silently orphans every
        // existing user's locally-encrypted envelope and last-upload timestamp.
        XCTAssertEqual(BackupEnvelopeStore.Keys.envelope, "lavasec.encryptedBackupEnvelope.pending")
        XCTAssertEqual(BackupEnvelopeStore.Keys.lastUploadedAt, "lavasec.encryptedBackup.lastUploadedAt")
    }

    func testSaveThenLoadRoundTripsEnvelope() throws {
        let storage = InMemoryBackupEnvelopeStorage()
        let store = BackupEnvelopeStore(storage: storage)
        let envelope = makeEnvelope()

        try store.saveEnvelope(envelope)

        XCTAssertEqual(store.loadEnvelope(), envelope)
        XCTAssertNotNil(storage.data[BackupEnvelopeStore.Keys.envelope])
    }

    func testLoadEnvelopeReturnsNilWhenAbsent() {
        let store = BackupEnvelopeStore(storage: InMemoryBackupEnvelopeStorage())
        XCTAssertNil(store.loadEnvelope())
    }

    func testLoadEnvelopeReturnsNilForCorruptData() {
        let storage = InMemoryBackupEnvelopeStorage()
        storage.set(Data("not json".utf8), forKey: BackupEnvelopeStore.Keys.envelope)
        let store = BackupEnvelopeStore(storage: storage)

        XCTAssertNil(store.loadEnvelope())
    }

    func testRecordUploadRoundTripsTimestamp() {
        let storage = InMemoryBackupEnvelopeStorage()
        let store = BackupEnvelopeStore(storage: storage)
        let uploadedAt = Date(timeIntervalSince1970: 1_700_500_000)

        store.recordUpload(at: uploadedAt)

        XCTAssertEqual(store.lastUploadedAt(), uploadedAt)
    }

    func testEstimatedByteSizeAddsReservedOverhead() {
        let store = BackupEnvelopeStore(storage: InMemoryBackupEnvelopeStorage())
        let envelope = makeEnvelope(ciphertextByteSize: 4_096)

        XCTAssertEqual(BackupEnvelopeStore.reservedOverheadBytes, 1_024)
        XCTAssertEqual(store.estimatedByteSize(for: envelope), 4_096 + 1_024)
    }

    func testCurrentStateIsOffWithoutEnvelope() {
        let store = BackupEnvelopeStore(storage: InMemoryBackupEnvelopeStorage())
        XCTAssertEqual(store.currentState(), .off)
    }

    func testCurrentStateIsWaitingForSignInWhenEnvelopeNotYetUploaded() throws {
        let storage = InMemoryBackupEnvelopeStorage()
        let store = BackupEnvelopeStore(storage: storage)
        try store.saveEnvelope(makeEnvelope(ciphertextByteSize: 2_000))

        XCTAssertEqual(store.currentState(), .waitingForSignIn(estimatedByteSize: 2_000 + 1_024))
    }

    func testCurrentStateIsSyncedWhenEnvelopeUploaded() throws {
        let storage = InMemoryBackupEnvelopeStorage()
        let store = BackupEnvelopeStore(storage: storage)
        let uploadedAt = Date(timeIntervalSince1970: 1_700_500_000)
        try store.saveEnvelope(makeEnvelope(ciphertextByteSize: 2_000))
        store.recordUpload(at: uploadedAt)

        XCTAssertEqual(
            store.currentState(),
            .synced(estimatedByteSize: 2_000 + 1_024, uploadedAt: uploadedAt)
        )
    }

    func testClearUploadMarkerKeepsEnvelopeAndReturnsToWaiting() throws {
        let storage = InMemoryBackupEnvelopeStorage()
        let store = BackupEnvelopeStore(storage: storage)
        try store.saveEnvelope(makeEnvelope(ciphertextByteSize: 2_000))
        store.recordUpload(at: Date(timeIntervalSince1970: 1_700_500_000))

        store.clearUploadMarker()

        XCTAssertNotNil(store.loadEnvelope())
        XCTAssertNil(store.lastUploadedAt())
        XCTAssertEqual(store.currentState(), .waitingForSignIn(estimatedByteSize: 2_000 + 1_024))
    }

    func testDeleteEnvelopeRemovesEnvelopeAndMarkerAndReportsOff() throws {
        let storage = InMemoryBackupEnvelopeStorage()
        let store = BackupEnvelopeStore(storage: storage)
        try store.saveEnvelope(makeEnvelope(ciphertextByteSize: 2_000))
        store.recordUpload(at: Date(timeIntervalSince1970: 1_700_500_000))

        store.deleteEnvelope()

        XCTAssertNil(store.loadEnvelope())
        XCTAssertNil(store.lastUploadedAt())
        XCTAssertEqual(store.currentState(), .off)
    }
}
