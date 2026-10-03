import XCTest
import LavaSecAppServices

final class BackupDeletionIntentTests: XCTestCase {
    func testAccountDeletionPreparationStaysFencedAcrossAllCheckpoints() throws {
        var intent = BackupDeletionIntent(accountID: "A", retainsEnvelopeForRecovery: true)
        XCTAssertEqual(intent.version, 3)
        for phase in [BackupDeletionIntent.Phase.remotePending, .localCleanupPending, .disabled] {
            intent.phase = phase
            XCTAssertEqual(try BackupDeletionIntent.decode(JSONEncoder().encode(intent)), intent)
            XCTAssertEqual(intent.canDeleteRemote(currentAccountID: "A"), phase == .remotePending)
            XCTAssertFalse(intent.canDeleteRemote(currentAccountID: "B"))
        }
    }

    func testSupplementalConfirmationMatchesOnlyItsExactPreparation() throws {
        let preparation = BackupDeletionIntent(accountID: "A", retainsEnvelopeForRecovery: true)
        var confirmed = preparation
        confirmed.phase = .localCleanupPending
        XCTAssertNotNil(preparation.operationID)
        XCTAssertTrue(try BackupDeletionIntent.decode(JSONEncoder().encode(confirmed)).confirmsLocalCleanup(of: preparation))
        XCTAssertFalse(preparation.confirmsLocalCleanup(of: preparation))
        XCTAssertFalse(confirmed.confirmsLocalCleanup(of: .init(accountID: "A", retainsEnvelopeForRecovery: true)))
        XCTAssertFalse(confirmed.confirmsLocalCleanup(of: .init(accountID: "B", retainsEnvelopeForRecovery: true)))
        XCTAssertFalse(confirmed.confirmsLocalCleanup(of: .init(accountID: "A")))
        let legacy = try BackupDeletionIntent.decode(Data(#"{"version":3,"accountID":"A","phase":"remotePending","retainsEnvelopeForRecovery":true}"#.utf8))
        XCTAssertNil(legacy.operationID)
        XCTAssertFalse(confirmed.confirmsLocalCleanup(of: legacy))
        var completed = preparation
        completed.phase = .disabled
        XCTAssertFalse(confirmed.confirmsLocalCleanup(of: completed))
    }

    func testPhasesRoundTripWithAccountBoundRemoteRetry() throws {
        for phase in [BackupDeletionIntent.Phase.remotePending, .localCleanupPending, .disabled] {
            let intent = BackupDeletionIntent(accountID: "account-A", phase: phase)
            XCTAssertEqual(try BackupDeletionIntent.decode(JSONEncoder().encode(intent)), intent)
            XCTAssertEqual(intent.blocksBackupWork, phase != .disabled)
            XCTAssertEqual(intent.canDeleteRemote(currentAccountID: "account-A"), phase == .remotePending)
            XCTAssertFalse(intent.canDeleteRemote(currentAccountID: "account-B"))
            XCTAssertFalse(intent.canDeleteRemote(currentAccountID: nil))
        }
    }

    func testMalformedUnknownOrUnboundRecordsDoNotBecomeMissingIntents() {
        for text in ["broken", #"{"version":2,"accountID":"A","phase":"remotePending"}"#,
                     #"{"version":1,"accountID":"","phase":"remotePending"}"#,
                     #"{"version":1,"accountID":" A","phase":"remotePending"}"#,
                     #"{"version":1,"accountID":"A","phase":"unknown"}"#] {
            XCTAssertThrowsError(try BackupDeletionIntent.decode(Data(text.utf8)))
        }
    }

    func testAccountCleanupRetainsRecoveryWithoutChangingLegacyOffRecords() throws {
        let legacy = try BackupDeletionIntent.decode(Data(#"{"version":1,"accountID":"A","phase":"localCleanupPending"}"#.utf8))
        XCTAssertNil(legacy.retainsEnvelopeForRecovery)
        let accountCleanup = BackupDeletionIntent(accountID: "A", phase: .localCleanupPending, retainsEnvelopeForRecovery: true)
        XCTAssertEqual(accountCleanup.version, 2, "Older builds must reject retention semantics they do not understand.")
        XCTAssertEqual(try BackupDeletionIntent.decode(JSONEncoder().encode(accountCleanup)), accountCleanup)
        XCTAssertTrue(accountCleanup.blocksBackupWork)
        XCTAssertFalse(accountCleanup.canDeleteRemote(currentAccountID: "A"))
        for record in [#"{"version":1,"accountID":"A","phase":"localCleanupPending","retainsEnvelopeForRecovery":true}"#,
                       #"{"version":2,"accountID":"A","phase":"remotePending","retainsEnvelopeForRecovery":true}"#] {
            XCTAssertThrowsError(try BackupDeletionIntent.decode(Data(record.utf8)))
        }
    }
}
