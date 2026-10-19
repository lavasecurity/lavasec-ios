import XCTest
@testable import LavaSecPresentation

final class FilterPreparationPresentationLifetimeTests: XCTestCase {
    func testOnlyCurrentConfirmedSuccessCanAcknowledgeTheFinalFill() {
        var lifetime = FilterPreparationPresentationLifetime()
        let first = lifetime.begin()
        XCTAssertFalse(lifetime.acknowledgeSuccess(id: first, confirmed: false))
        XCTAssertFalse(lifetime.successWasPresented)
        let second = lifetime.begin()
        XCTAssertFalse(lifetime.acknowledgeSuccess(id: first, confirmed: true))
        XCTAssertFalse(lifetime.successWasPresented)
        XCTAssertTrue(lifetime.acknowledgeSuccess(id: second, confirmed: true))
        XCTAssertTrue(lifetime.successWasPresented)
    }

    func testRendererRemountDoesNotRepeatATerminalAnnouncement() {
        var lifetime = FilterPreparationPresentationLifetime()
        let first = lifetime.begin()
        XCTAssertTrue(lifetime.claimAnnouncement(id: first, outcome: "failure"))
        XCTAssertFalse(lifetime.claimAnnouncement(id: first, outcome: "failure"))
        let retry = lifetime.begin()
        XCTAssertFalse(lifetime.claimAnnouncement(id: first, outcome: "success"))
        XCTAssertTrue(lifetime.claimAnnouncement(id: retry, outcome: "failure"))
        XCTAssertFalse(lifetime.successWasPresented)
    }

    func testMissingRendererHasABoundedNativeDeadlineWithoutManufacturingSuccess() {
        var lifetime = FilterPreparationPresentationLifetime()
        let id = lifetime.begin()
        XCTAssertFalse(lifetime.shouldUseTerminalFallback(id: id, now: 1_000))
        XCTAssertTrue(lifetime.beginTerminal(id: id, outcome: "success", now: 100))
        XCTAssertFalse(lifetime.shouldUseTerminalFallback(id: id, now: 107.999))
        XCTAssertTrue(lifetime.shouldUseTerminalFallback(id: id, now: 108))
        XCTAssertFalse(lifetime.successWasPresented)
        XCTAssertFalse(lifetime.beginTerminal(id: id, outcome: "success", now: 107))
        XCTAssertEqual(lifetime.terminalDeadline, 108)
    }

    func testMeaningfulLateMountGetsItsFullFillAndGlyphTimelineOnlyOnce() {
        var lifetime = FilterPreparationPresentationLifetime()
        let id = lifetime.begin()
        lifetime.beginTerminal(id: id, outcome: "success", now: 100)
        XCTAssertTrue(lifetime.noteRenderedSuccess(id: id, now: 107.9))
        XCTAssertEqual(lifetime.terminalDeadline, 109.9)
        XCTAssertFalse(lifetime.shouldUseTerminalFallback(id: id, now: 109.1))
        XCTAssertFalse(lifetime.noteRenderedSuccess(id: id, now: 109.8))
        XCTAssertTrue(lifetime.shouldUseTerminalFallback(id: id, now: 109.9))
    }

    func testFallbackAndRendererShareOneAnnouncementAndSupersessionRevokesTheDeadline() {
        var lifetime = FilterPreparationPresentationLifetime()
        let old = lifetime.begin()
        lifetime.beginTerminal(id: old, outcome: "failure:Network", now: 100)
        XCTAssertFalse(lifetime.noteRenderedSuccess(id: old, now: 101))
        XCTAssertTrue(lifetime.shouldUseTerminalFallback(id: old, now: 108))
        XCTAssertTrue(lifetime.claimAnnouncement(id: old, outcome: "failure:Network"))
        XCTAssertFalse(lifetime.claimAnnouncement(id: old, outcome: "failure:Network"))
        let new = lifetime.begin()
        XCTAssertNil(lifetime.terminalDeadline)
        XCTAssertFalse(lifetime.shouldUseTerminalFallback(id: old, now: 1_000))
        XCTAssertFalse(lifetime.beginTerminal(id: old, outcome: "success", now: 1_000))
        XCTAssertFalse(lifetime.shouldUseTerminalFallback(id: new, now: 1_000))
    }

    func testRendererArrivingAfterDeadlineCannotRenewTheNativeHold() {
        var lifetime = FilterPreparationPresentationLifetime()
        let id = lifetime.begin()
        lifetime.beginTerminal(id: id, outcome: "success", now: 100)
        XCTAssertFalse(lifetime.noteRenderedSuccess(id: id, now: 108))
        XCTAssertEqual(lifetime.terminalDeadline, 108)
    }
}
