import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterEditDraftEditorTests: XCTestCase {
    private func draft(blocked: Set<String> = [], allowed: Set<String> = []) -> FilterEditDraft {
        FilterEditDraft(
            enabledBlocklistIDs: [],
            customBlocklists: [],
            blockedDomains: blocked,
            allowedDomains: allowed
        )
    }

    private func validator(threats: [String] = []) -> AllowlistValidator {
        var guardrail = DomainRuleSet()
        for threat in threats {
            try? guardrail.insert(domain: threat, matchesSubdomains: true)
        }
        return AllowlistValidator(nonAllowableThreatRules: guardrail)
    }

    // MARK: - Blocked domains

    func testAddBlockedDomainNormalizesAndAccepts() {
        let (next, result) = FilterEditDraftEditor.addBlockedDomain("Ads.Example.com.", to: draft(), maxBlockedDomains: 10)
        XCTAssertTrue(result.isAccepted)
        XCTAssertEqual(result.normalizedDomain, "ads.example.com")
        XCTAssertTrue(next.blockedDomains.contains("ads.example.com"))
    }

    func testAddBlockedDomainRejectsInvalidWithoutMutating() {
        let (next, result) = FilterEditDraftEditor.addBlockedDomain("not a domain", to: draft(), maxBlockedDomains: 10)
        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(next.blockedDomains.isEmpty)
    }

    func testAddBlockedDomainRejectsDuplicate() {
        let (next, result) = FilterEditDraftEditor.addBlockedDomain(
            "ads.example.com",
            to: draft(blocked: ["ads.example.com"]),
            maxBlockedDomains: 10
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertEqual(result.title, "Already blocked")
        XCTAssertEqual(next.blockedDomains.count, 1)
    }

    func testAddBlockedDomainRejectsAtLimit() {
        let (next, result) = FilterEditDraftEditor.addBlockedDomain(
            "new.example.com",
            to: draft(blocked: ["a.com", "b.com"]),
            maxBlockedDomains: 2
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertEqual(result.title, "Blocked domain limit reached")
        XCTAssertEqual(next.blockedDomains.count, 2)
    }

    func testRemoveBlockedDomain() {
        let next = FilterEditDraftEditor.removeBlockedDomain("ads.example.com", from: draft(blocked: ["ads.example.com", "x.com"]))
        XCTAssertFalse(next.blockedDomains.contains("ads.example.com"))
        XCTAssertTrue(next.blockedDomains.contains("x.com"))
    }

    func testUndoBlockedDomainReinsertsWhenConfigured() {
        let next = FilterEditDraftEditor.undoBlockedDomainChange(
            "ads.example.com",
            in: draft(blocked: []),
            configuredBlockedDomains: ["ads.example.com"]
        )
        XCTAssertTrue(next.blockedDomains.contains("ads.example.com"))
    }

    func testUndoBlockedDomainRemovesWhenNotConfigured() {
        let next = FilterEditDraftEditor.undoBlockedDomainChange(
            "new.example.com",
            in: draft(blocked: ["new.example.com"]),
            configuredBlockedDomains: []
        )
        XCTAssertFalse(next.blockedDomains.contains("new.example.com"))
    }

    // MARK: - Allowed domains

    func testAddAllowedDomainAccepts() {
        let (next, result) = FilterEditDraftEditor.addAllowedDomain(
            "good.example.com",
            to: draft(),
            maxAllowedDomains: 10,
            validator: validator()
        )
        XCTAssertTrue(result.isAccepted)
        XCTAssertTrue(next.allowedDomains.contains("good.example.com"))
    }

    func testAddAllowedDomainRejectedByThreatGuardrail() {
        let (next, result) = FilterEditDraftEditor.addAllowedDomain(
            "malware.example.com",
            to: draft(),
            maxAllowedDomains: 10,
            validator: validator(threats: ["malware.example.com"])
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(next.allowedDomains.isEmpty)
    }

    func testAddAllowedDomainRejectsDuplicate() {
        let (next, result) = FilterEditDraftEditor.addAllowedDomain(
            "good.example.com",
            to: draft(allowed: ["good.example.com"]),
            maxAllowedDomains: 10,
            validator: validator()
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertEqual(result.title, "Already allowed")
        XCTAssertEqual(next.allowedDomains.count, 1)
    }

    func testAddAllowedDomainRejectsAtLimit() {
        let (_, result) = FilterEditDraftEditor.addAllowedDomain(
            "new.example.com",
            to: draft(allowed: ["a.com", "b.com"]),
            maxAllowedDomains: 2,
            validator: validator()
        )
        XCTAssertFalse(result.isAccepted)
        XCTAssertEqual(result.title, "Allowed exception limit reached")
    }

    func testRemoveAndUndoAllowedDomain() {
        let removed = FilterEditDraftEditor.removeAllowedDomain("good.example.com", from: draft(allowed: ["good.example.com"]))
        XCTAssertFalse(removed.allowedDomains.contains("good.example.com"))

        let undone = FilterEditDraftEditor.undoAllowedDomainChange(
            "good.example.com",
            in: draft(allowed: []),
            configuredAllowedDomains: ["good.example.com"]
        )
        XCTAssertTrue(undone.allowedDomains.contains("good.example.com"))
    }
}
