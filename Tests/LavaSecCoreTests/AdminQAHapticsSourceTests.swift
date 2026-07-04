import XCTest

final class AdminQAHapticsSourceTests: XCTestCase {
    func testPhoneQAIncludesStandaloneProtectionHapticPreviews() throws {
        let source = try readSource(.adminQAView)
        let phoneQABlock = try sourceBlock(
            in: source,
            startingAt: "struct PhoneQAView: View",
            endingBefore: "private struct AdminQAActionRow"
        )
        let previewBlock = try sourceBlock(
            in: source,
            startingAt: "private enum PhoneQAHapticPreview",
            endingBefore: "private struct PhoneQAHapticPreviewRow"
        )

        XCTAssertTrue(phoneQABlock.contains("LavaSectionGroup(\"Haptics\")"))
        XCTAssertTrue(phoneQABlock.contains("ForEach(Array(PhoneQAHapticPreview.allCases.enumerated()), id: \\.element.id)"))
        XCTAssertTrue(phoneQABlock.contains("ProtectionHapticFeedback.play(preview.feedback)"))
        XCTAssertTrue(phoneQABlock.contains("PhoneQAHapticPreviewRow(preview: preview)"))
        XCTAssertTrue(previewBlock.contains("case turnOnSuccess"))
        XCTAssertTrue(previewBlock.contains("case turnOnFailure"))
        XCTAssertTrue(previewBlock.contains("case turnOff"))
        XCTAssertTrue(previewBlock.contains("case guardianTap"))
        XCTAssertTrue(previewBlock.contains("\"Turn On Success\""))
        XCTAssertTrue(previewBlock.contains("\"Turn On Failure\""))
        XCTAssertTrue(previewBlock.contains("\"Turn Off\""))
        XCTAssertTrue(previewBlock.contains("\"Guardian Tap\""))
        XCTAssertTrue(previewBlock.contains("\"Notification error\""))
        XCTAssertTrue(previewBlock.contains("\"Notification warning\""))
        XCTAssertTrue(previewBlock.contains("\"Light impact\""))
        XCTAssertFalse(previewBlock.contains("\"Two light impacts\""))
        XCTAssertFalse(previewBlock.contains("\"Medium impact\""))
        XCTAssertTrue(previewBlock.contains(".protectionOnSucceeded"))
        XCTAssertTrue(previewBlock.contains(".protectionStartFailed"))
        XCTAssertTrue(previewBlock.contains(".protectionTurnedOff"))
        XCTAssertTrue(previewBlock.contains(".guardianTapAcknowledged"))
    }
}
