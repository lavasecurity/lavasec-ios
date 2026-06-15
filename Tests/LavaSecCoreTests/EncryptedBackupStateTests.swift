import XCTest
@testable import LavaSecCore

final class EncryptedBackupStateTests: XCTestCase {
    func testIsConfigured() {
        XCTAssertFalse(EncryptedBackupState.off.isConfigured)
        XCTAssertTrue(EncryptedBackupState.waitingForSignIn(estimatedByteSize: 1).isConfigured)
        XCTAssertTrue(EncryptedBackupState.synced(estimatedByteSize: 1, uploadedAt: Date()).isConfigured)
        XCTAssertTrue(EncryptedBackupState.failed(message: "x").isConfigured)
    }

    func testOffCopyDependsOnSignInState() {
        XCTAssertEqual(
            EncryptedBackupState.off.displayText(isAccountSignedIn: false).summary,
            "Off"
        )
        XCTAssertEqual(
            EncryptedBackupState.off.displayText(isAccountSignedIn: false).detail,
            "Sign in to set up encrypted backup."
        )
        // Signed in but no backup yet: nudge toward setup rather than showing "Off".
        XCTAssertEqual(
            EncryptedBackupState.off.displayText(isAccountSignedIn: true).summary,
            "Pending setup"
        )
        XCTAssertEqual(
            EncryptedBackupState.off.displayText(isAccountSignedIn: true).detail,
            "Set up encrypted backup for this account."
        )
    }

    func testWaitingForSignInCopyDependsOnSignInState() {
        let state = EncryptedBackupState.waitingForSignIn(estimatedByteSize: 2_048)
        XCTAssertEqual(state.displayText(isAccountSignedIn: false).summary, "Ready after sign-in")
        XCTAssertEqual(state.displayText(isAccountSignedIn: false).detail, "Encrypted locally. Sign in to upload.")
        XCTAssertEqual(state.displayText(isAccountSignedIn: true).summary, "Not uploaded yet")
        XCTAssertEqual(
            state.displayText(isAccountSignedIn: true).detail,
            "Encrypted locally. Back up now to store a copy online."
        )
    }

    func testSyncedCopyShowsUploadTimeAndSize() {
        let uploadedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let state = EncryptedBackupState.synced(estimatedByteSize: 4_096, uploadedAt: uploadedAt)
        let display = state.displayText(isAccountSignedIn: true)

        XCTAssertTrue(display.summary.hasPrefix("Last uploaded "))
        XCTAssertTrue(display.summary.contains(LocalLogTimestampFormatter.string(from: uploadedAt)))
        XCTAssertTrue(display.detail.contains("Latest encrypted settings backup size is"))
    }

    func testFailedCopySurfacesMessage() {
        let state = EncryptedBackupState.failed(message: "Upload failed")
        XCTAssertEqual(state.displayText(isAccountSignedIn: true).summary, "Needs attention")
        XCTAssertEqual(state.displayText(isAccountSignedIn: true).detail, "Upload failed")
    }

    func testSummaryAndDetailTextUseSignedOutVariant() {
        XCTAssertEqual(EncryptedBackupState.off.summaryText, "Off")
        XCTAssertEqual(EncryptedBackupState.off.detailText, "Sign in to set up encrypted backup.")
    }
}
