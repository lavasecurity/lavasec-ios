import XCTest
import LavaSecCore

final class BackupRemoteMetadataTests: XCTestCase {
    func testLegacyRestoreTimestampIsNeverAnUploadDate() throws {
        let data = Data(#"{"user_id":"a","updated_at":"2026-09-12T09:00:00Z","last_restored_at":"2026-09-12T09:00:00Z"}"#.utf8)
        let metadata = try JSONDecoder().decode(BackupRemoteMetadata.self, from: data)
        XCTAssertEqual(metadata.userID, "a")
        XCTAssertNil(metadata.uploadedAt)
    }
    func testUploadTimestampAcceptsWholeAndFractionalSeconds() throws {
        for timestamp in ["2026-09-12T09:00:00Z", "2026-09-12T09:00:00.123456+00:00"] {
            let data = Data("{\"user_id\":\"a\",\"uploaded_at\":\"\(timestamp)\"}".utf8)
            XCTAssertNotNil(try JSONDecoder().decode(BackupRemoteMetadata.self, from: data).uploadedAt)
        }
    }
    func testMissingOrUnreadableTimestampKeepsPresenceWithoutFabricatingTime() throws {
        for suffix in ["", ",\"uploaded_at\":null", ",\"uploaded_at\":\"invalid\""] {
            let data = Data("{\"user_id\":\"a\"\(suffix)}".utf8)
            XCTAssertNil(try JSONDecoder().decode(BackupRemoteMetadata.self, from: data).uploadedAt)
        }
    }
    func testAutomaticUploadHasFiveMinuteTrailingDeadlineAndCancellationFence() {
        var schedule = AutomaticBackupSchedule()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = schedule.changed(at: start)
        XCTAssertFalse(schedule.canRun(token: first, at: start.addingTimeInterval(299)))
        XCTAssertTrue(schedule.canRun(token: first, at: start.addingTimeInterval(300)))
        let second = schedule.changed(at: start.addingTimeInterval(240))
        XCTAssertFalse(schedule.canRun(token: first, at: start.addingTimeInterval(540)))
        XCTAssertFalse(schedule.canRun(token: second, at: start.addingTimeInterval(539)))
        XCTAssertTrue(schedule.canRun(token: second, at: start.addingTimeInterval(540)))
        schedule.cancel()
        XCTAssertFalse(schedule.canRun(token: second, at: start.addingTimeInterval(900)))
    }
}

final class ChainedFallbackCompactPresentationTests: XCTestCase {
    func testCompactStatusIsOneConfigurationRedactedMessageAndOnlyResolutionsAreGreen() {
        let states: [ChainedFallbackStatus] = [.off, .awaitingSession, .pendingDisable, .awaitingRestart,
            .unavailableInFullTunnel, .readyUnused, .working(rescues: 8), .notForwarded(attempts: 99),
            .answeringWithoutResolving(answers: 20), .noneUsable(outcomes: [])]
        XCTAssertEqual(Set(states.map(\.compactMessage)).count, states.count)
        for state in states {
            XCTAssertFalse(state.compactMessage.contains("99"))
            XCTAssertFalse(state.compactMessage.contains("20"))
            XCTAssertFalse(state.compactMessage.contains("8"))
            if case .working = state { XCTAssertTrue(state.isCompactSuccess) }
            else { XCTAssertFalse(state.isCompactSuccess) }
        }
        XCTAssertEqual(ChainedFallbackStatus.working(rescues: 8).compactMessage, "Fallback DNS has handled lookups")
    }
}
