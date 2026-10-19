import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class BackupRecoveryPhraseTests: XCTestCase {
    func testClearingAPastedWordCannotSubmitTheHiddenOriginalPhrase() {
        var input = BackupRecoveryPhraseInput()
        input.setPastedPhrase("river maple signal velvet orbit silver canyon quartz")
        XCTAssertFalse(input.secret.isEmpty)
        input.setWord("", at: 3)
        XCTAssertEqual(input.words[3], "")
        XCTAssertTrue(input.pastedPhrase.isEmpty)
        XCTAssertTrue(input.secret.isEmpty)
        input.setWord("newword", at: 3)
        XCTAssertEqual(input.secret, "river maple signal newword orbit silver canyon quartz")
    }
    func testRepastingReplacesTheDraftAndInvalidWordCallbacksCannotEraseIt() {
        var input = BackupRecoveryPhraseInput()
        input.setPastedPhrase("  river maple  ")
        input.setWord("ignored", at: -1)
        input.setWord("ignored", at: BackupRecoveryPhrase.wordCount)
        XCTAssertEqual(input.secret, "river maple")
        input.setWord("edited", at: 0)
        XCTAssertTrue(input.secret.isEmpty)
        input.setPastedPhrase("one two three four five six seven eight")
        XCTAssertEqual(input.words, ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        XCTAssertEqual(input.secret, "one two three four five six seven eight")
    }
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
