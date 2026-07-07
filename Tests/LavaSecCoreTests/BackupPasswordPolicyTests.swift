import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class BackupPasswordPolicyTests: XCTestCase {
    func testReportsEachRequirementIndependently() {
        let result = BackupPasswordPolicy.validate(password: "abcdefg", confirmation: "abcdefg")

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.requirements.first { $0.id == .minimumLength }!.isSatisfied)
        XCTAssertFalse(result.requirements.first { $0.id == .number }!.isSatisfied)
        XCTAssertFalse(result.requirements.first { $0.id == .symbol }!.isSatisfied)
        XCTAssertTrue(result.requirements.first { $0.id == .matchesConfirmation }!.isSatisfied)
    }

    func testAcceptsEightCharactersNumberSymbolAndMatch() {
        let result = BackupPasswordPolicy.validate(password: "lava2026!", confirmation: "lava2026!")

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.requirements.allSatisfy(\.isSatisfied))
    }

    func testRejectsMismatchedConfirmation() {
        let result = BackupPasswordPolicy.validate(password: "lava2026!", confirmation: "lava2027!")

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.requirements.first { $0.id == .matchesConfirmation }!.isSatisfied)
    }

    func testWhitespaceDoesNotSatisfySymbolRequirement() {
        let result = BackupPasswordPolicy.validate(password: "lava 2026", confirmation: "lava 2026")

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.requirements.first { $0.id == .symbol }!.isSatisfied)
    }
}
