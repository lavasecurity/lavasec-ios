import XCTest
import LavaSecCore

final class PasscodeEntrySessionTests: XCTestCase {
    func testSetupRequiresMatchingConfirmationAndForgetsMismatchedFirstEntry() {
        var session = PasscodeEntrySession(mode: .setup)
        XCTAssertEqual(session.enter("12"), .none)
        XCTAssertFalse(session.confirming)
        XCTAssertEqual(session.enter("1234"), .none)
        XCTAssertTrue(session.confirming)
        XCTAssertEqual(session.enter("4321"), .none)
        XCTAssertFalse(session.confirming)
        XCTAssertEqual(session.message, "Passcodes did not match")
        XCTAssertEqual(session.enter("5678"), .none)
        XCTAssertEqual(session.enter("5678"), .setPasscode("5678"))
    }

    func testAuthenticationSubmitsOnlyCompleteNativeInputAndKeepsFailure() {
        var session = PasscodeEntrySession(mode: .authenticate)
        XCTAssertEqual(session.enter("a12b"), .none)
        XCTAssertEqual(session.enter("a12345"), .authenticate("1234"))
        session.failed("Wrong passcode")
        XCTAssertEqual(session.message, "Wrong passcode")
        XCTAssertEqual(session.enter("9876"), .authenticate("9876"))
    }

    func testPersistenceFailureStartsFreshSetupRatherThanReusingConfirmation() {
        var session = PasscodeEntrySession(mode: .setup)
        _ = session.enter("1234")
        XCTAssertEqual(session.enter("1234"), .setPasscode("1234"))
        session.failed("Unavailable")
        XCTAssertFalse(session.confirming)
        XCTAssertEqual(session.enter("5678"), .none)
        XCTAssertEqual(session.enter("5678"), .setPasscode("5678"))
    }
}
