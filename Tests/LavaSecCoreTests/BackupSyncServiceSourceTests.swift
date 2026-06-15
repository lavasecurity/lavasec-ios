import XCTest

final class BackupSyncServiceSourceTests: XCTestCase {
    func testBackupMetadataPersistsServerRecoveryShare() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSyncService.swift")

        XCTAssertTrue(source.contains("let serverRecoveryShare: String?"))
        XCTAssertTrue(source.contains("case serverRecoveryShare = \"server_recovery_share\""))
        XCTAssertTrue(source.contains("serverRecoveryShare = envelope.serverRecoveryShare"))
        XCTAssertTrue(source.contains("serverRecoveryShare: metadata.serverRecoveryShare"))
    }

    func testDeleteRemoteHardDeletesViaHTTPDelete() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSyncService.swift")

        XCTAssertTrue(source.contains("func deleteRemote(session: BackupAccountSession) async throws"))
        XCTAssertTrue(source.contains("request.httpMethod = \"DELETE\""))
        // Security-critical: the delete must stay scoped to the row owner so it can
        // never widen to other accounts' backups.
        XCTAssertTrue(source.contains("path: \"user_backups\""))
        XCTAssertTrue(source.contains("URLQueryItem(name: \"user_id\", value: \"eq.\\(session.userID)\")"))
        XCTAssertTrue(source.contains("request.setValue(\"return=minimal\", forHTTPHeaderField: \"Prefer\")"))
        // Hard delete, not a soft `disabled_at` flag.
        XCTAssertFalse(source.contains("UserBackupDisablePatch"))
    }

    func testBackupSyncErrorsUseActionableCopy() throws {
        let source = try Self.readAppSource("LavaSecApp/BackupSyncService.swift")

        XCTAssertTrue(source.contains("friendlyMessage(forStatusCode statusCode: Int)"))
        XCTAssertTrue(source.contains("Sign in again to sync encrypted backup."))
        XCTAssertTrue(source.contains("This backup is not available for this account."))
        XCTAssertTrue(source.contains("No encrypted backup was found for this account."))
        XCTAssertTrue(source.contains("Backup sync conflict. Try Back Up Now again."))
        XCTAssertTrue(source.contains("Too many backup attempts. Wait a minute, then try again."))
        XCTAssertTrue(source.contains("Lava backup service is temporarily unavailable. Try again later."))
        XCTAssertFalse(source.contains("The backup server returned status \\(statusCode)."))
    }

    private static func readAppSource(_ relativePath: String) throws -> String {
        let current = URL(fileURLWithPath: #filePath)
        let packageRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
