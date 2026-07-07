import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class BackupRecoveryPhraseTests: XCTestCase {
    func testGeneratesEightReadableTokens() throws {
        let phrase = try BackupRecoveryPhrase.generate()
        let words = BackupRecoveryPhrase.words(from: phrase)

        XCTAssertEqual(words.count, BackupRecoveryPhrase.wordCount)
        XCTAssertTrue(words.allSatisfy { $0.count == 4 })
        XCTAssertTrue(words.allSatisfy { word in
            word.allSatisfy { $0.isLowercase }
        })
    }

    func testDeviceSecretGeneratorCreatesOpaqueSecret() throws {
        let secret = try BackupDeviceSecret.generate()

        XCTAssertGreaterThanOrEqual(secret.count, 43)
        XCTAssertFalse(secret.contains(" "))
    }

    func testNormalizesSpaceDelimitedPhrase() {
        let words = BackupRecoveryPhrase.words(
            from: "River   Maple Signal\nVelvet Orbit Silver Canyon Quartz"
        )

        XCTAssertEqual(words, [
            "river",
            "maple",
            "signal",
            "velvet",
            "orbit",
            "silver",
            "canyon",
            "quartz"
        ])
    }

    func testNormalizesNumberedPhrase() {
        let words = BackupRecoveryPhrase.words(
            from: "1. river 2) maple 3. signal 4) velvet 5. orbit 6) silver 7. canyon 8) quartz"
        )

        XCTAssertEqual(words, [
            "river",
            "maple",
            "signal",
            "velvet",
            "orbit",
            "silver",
            "canyon",
            "quartz"
        ])
    }

    func testFillSlotsPadsMissingWords() {
        let slots = BackupRecoveryPhrase.fillSlots(from: "river maple signal")

        XCTAssertEqual(slots, [
            "river",
            "maple",
            "signal",
            "",
            "",
            "",
            "",
            ""
        ])
    }

    func testPhraseFromSlotsTrimsAndLowercasesWords() {
        let phrase = BackupRecoveryPhrase.phrase(from: [
            " River ",
            "MAPLE",
            "signal",
            "Velvet",
            " orbit",
            "SILVER ",
            "canyon",
            "quartz"
        ])

        XCTAssertEqual(phrase, "river maple signal velvet orbit silver canyon quartz")
    }
}
