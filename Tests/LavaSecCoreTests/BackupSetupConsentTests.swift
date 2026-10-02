import XCTest
import LavaSecCore

final class BackupSetupConsentTests: XCTestCase {
    func testBothAcknowledgmentsAllowCompletionWithoutCopying() {
        var consent = BackupSetupConsent()
        consent.savedRecoveryPhrase = true
        XCTAssertFalse(consent.canFinish)
        consent.understandsNoRecovery = true
        XCTAssertTrue(consent.canFinish)
        XCTAssertFalse(consent.copiedRecoveryPhrase)
        consent.recordCopy()
        XCTAssertTrue(consent.savedRecoveryPhrase)
        XCTAssertTrue(consent.understandsNoRecovery)
        XCTAssertTrue(consent.canFinish)
    }

    func testCopyDoesNotAcceptEitherAcknowledgment() {
        var consent = BackupSetupConsent()
        XCTAssertFalse(consent.copiedRecoveryPhrase)
        consent.recordCopy()
        XCTAssertTrue(consent.copiedRecoveryPhrase)
        XCTAssertFalse(consent.savedRecoveryPhrase)
        XCTAssertFalse(consent.understandsNoRecovery)
        XCTAssertFalse(consent.canFinish)
        consent.savedRecoveryPhrase = true
        XCTAssertFalse(consent.canFinish)
        consent.understandsNoRecovery = true
        XCTAssertTrue(consent.canFinish)
    }

    func testRecopyAndWithinAttemptNavigationPreserveExplicitAcknowledgments() {
        var consent = BackupSetupConsent()
        consent.recordCopy()
        consent.savedRecoveryPhrase = true
        consent.understandsNoRecovery = true
        let before = consent
        consent.recordCopy()
        XCTAssertEqual(consent, before)
        XCTAssertTrue(consent.canFinish)
    }

    func testNewPhraseOrMethodResetsAllConsentAndChangesAttemptIdentity() {
        var consent = BackupSetupConsent()
        consent.recordCopy()
        consent.savedRecoveryPhrase = true
        consent.understandsNoRecovery = true
        let oldID = consent.attemptID
        consent.reset()
        XCTAssertNotEqual(consent.attemptID, oldID)
        XCTAssertFalse(consent.copiedRecoveryPhrase)
        XCTAssertFalse(consent.savedRecoveryPhrase)
        XCTAssertFalse(consent.understandsNoRecovery)
        XCTAssertFalse(consent.canFinish)
    }
}
