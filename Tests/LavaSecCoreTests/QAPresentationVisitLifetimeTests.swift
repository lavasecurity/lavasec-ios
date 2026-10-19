import XCTest
@testable import LavaSecPresentation

final class QAPresentationVisitLifetimeTests: XCTestCase {
    func testClosedVisitCannotReappearAfterAuthenticationOrDelayedEntry() throws {
        var lifetime = QAPresentationVisitLifetime()
        let ticket = try XCTUnwrap(lifetime.requestEntry(id: "old"))
        lifetime.retire(id: "old")
        XCTAssertFalse(lifetime.admit(id: "old", ticket: ticket))
        XCTAssertNil(lifetime.requestEntry(id: "old"))
        XCTAssertNil(lifetime.currentID)
    }

    func testNewAuthenticationRequestSupersedesOldCallback() throws {
        var lifetime = QAPresentationVisitLifetime()
        let old = try XCTUnwrap(lifetime.requestEntry(id: "old"))
        let new = try XCTUnwrap(lifetime.requestEntry(id: "new"))
        XCTAssertFalse(lifetime.admit(id: "old", ticket: old))
        XCTAssertTrue(lifetime.admit(id: "new", ticket: new))
        XCTAssertNil(lifetime.requestEntry(id: "old"))
        XCTAssertEqual(lifetime.currentID, "new")
    }

    func testLateCleanupCannotRevokeAnotherVisitsPendingAdmission() throws {
        var lifetime = QAPresentationVisitLifetime()
        let ticket = try XCTUnwrap(lifetime.requestEntry(id: "new"))
        lifetime.retire(id: "old")
        XCTAssertTrue(lifetime.admit(id: "new", ticket: ticket))
        XCTAssertEqual(lifetime.currentID, "new")
    }

    func testNewQAFlowRetiresCoveredVisitBeforeAuthenticationCompletes() throws {
        var lifetime = QAPresentationVisitLifetime()
        let old = try XCTUnwrap(lifetime.requestEntry(id: "covered"))
        lifetime.retireSuperseded(by: "sheet")
        XCTAssertFalse(lifetime.admit(id: "covered", ticket: old))
        XCTAssertNil(lifetime.requestEntry(id: "covered"))
        let sheet = try XCTUnwrap(lifetime.requestEntry(id: "sheet"))
        XCTAssertTrue(lifetime.admit(id: "sheet", ticket: sheet))
        XCTAssertEqual(lifetime.currentID, "sheet")
    }

    func testNewQAFlowRetiresAlreadyAdmittedCoveredVisit() throws {
        var lifetime = QAPresentationVisitLifetime()
        let old = try XCTUnwrap(lifetime.requestEntry(id: "covered"))
        XCTAssertTrue(lifetime.admit(id: "covered", ticket: old))
        lifetime.retireSuperseded(by: "sheet")
        XCTAssertNil(lifetime.currentID)
        XCTAssertNil(lifetime.requestEntry(id: "covered"))
        XCTAssertNotNil(lifetime.requestEntry(id: "sheet"))
    }
}
