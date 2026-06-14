import XCTest

final class AdminQAHapticsSourceTests: XCTestCase {
    func testPhoneQAIncludesStandaloneProtectionHapticPreviews() throws {
        let source = try Self.source(named: "AdminQAView.swift", in: "LavaSecApp")
        let phoneQABlock = try Self.sourceBlock(
            in: source,
            startingAt: "struct PhoneQAView: View",
            endingBefore: "private struct AdminQAActionRow"
        )
        let previewBlock = try Self.sourceBlock(
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
        XCTAssertTrue(previewBlock.contains("\"Turn On Success\""))
        XCTAssertTrue(previewBlock.contains("\"Turn On Failure\""))
        XCTAssertTrue(previewBlock.contains("\"Turn Off\""))
        XCTAssertTrue(previewBlock.contains("\"Notification error\""))
        XCTAssertTrue(previewBlock.contains("\"Notification warning\""))
        XCTAssertFalse(previewBlock.contains("\"Two light impacts\""))
        XCTAssertFalse(previewBlock.contains("\"Medium impact\""))
        XCTAssertTrue(previewBlock.contains(".protectionOnSucceeded"))
        XCTAssertTrue(previewBlock.contains(".protectionStartFailed"))
        XCTAssertTrue(previewBlock.contains(".protectionTurnedOff"))
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        guard endMarker != "*** end ***" else {
            return String(suffix)
        }

        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
