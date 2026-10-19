import XCTest
@testable import LavaSecPresentation

final class FilterImportPhotoLifetimeTests: XCTestCase {
    func testLeavingTheMethodScreenReleasesPhotoAndLateDecodeCannotClearItsReplacement() throws {
        var lifetime = FilterImportPhotoLifetime()
        let abandoned = try XCTUnwrap(lifetime.begin())

        // The picker has dismissed but decoding is in flight when Enter Code
        // changes the stage. Returning to the menu must permit another photo.
        lifetime.cancel()
        let replacement = try XCTUnwrap(lifetime.begin())
        XCTAssertNotEqual(abandoned, replacement)
        XCTAssertFalse(lifetime.finish(abandoned))
        XCTAssertEqual(lifetime.requestID, replacement)
        XCTAssertNil(lifetime.begin())
        XCTAssertTrue(lifetime.finish(replacement))
        XCTAssertNil(lifetime.requestID)
    }

    func testCurrentPhotoCompletesOnceAndReopensTheRowForRetry() throws {
        var lifetime = FilterImportPhotoLifetime()
        let selection = try XCTUnwrap(lifetime.begin())
        XCTAssertNil(lifetime.begin(), "Repeated taps cannot create a second picker.")
        XCTAssertTrue(lifetime.finish(selection))
        XCTAssertFalse(lifetime.finish(selection))
        XCTAssertNotNil(lifetime.begin(), "Cancel or decode failure must leave the photo row reusable.")
    }

    func testRetiringAnIdleOrPendingVisitCannotLeavePhotoBusy() throws {
        var lifetime = FilterImportPhotoLifetime()
        lifetime.cancel()
        let pending = try XCTUnwrap(lifetime.begin())
        lifetime.cancel()
        lifetime.cancel()
        XCTAssertNil(lifetime.requestID)
        XCTAssertFalse(lifetime.finish(pending))
        XCTAssertNotNil(lifetime.begin())
    }
}
