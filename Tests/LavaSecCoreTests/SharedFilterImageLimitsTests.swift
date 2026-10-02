import XCTest
@testable import LavaSecKit

/// Behavioural tests for the bounds applied to a picked image before decoding.
///
/// These exist because the byte cap alone was never a memory bound: the decoder
/// previously built a full-resolution bitmap and only then resized it, so a small
/// file declaring huge dimensions could terminate the app. The pixel rule is the
/// one that actually holds, so it gets real tests rather than a source pin.
///
/// Plan: `lavasec-infra/plans/2026-07-14-recipient-first-shared-filter-card-plan.md`
final class SharedFilterImageLimitsTests: XCTestCase {

    // MARK: Bytes

    func testAcceptsAByteCountAtTheCap() {
        XCTAssertNoThrow(
            try SharedFilterImageLimits.validate(byteCount: SharedFilterImageLimits.maximumByteCount)
        )
    }

    func testRejectsOneByteOverTheCap() {
        XCTAssertThrowsError(
            try SharedFilterImageLimits.validate(byteCount: SharedFilterImageLimits.maximumByteCount + 1)
        ) { error in
            XCTAssertEqual(error as? SharedFilterImageLimits.Rejection, .tooManyBytes)
        }
    }

    // MARK: Pixels

    func testAcceptsATypicalShareCard() {
        // The card this feature generates: 1080 × 1350.
        XCTAssertNoThrow(try SharedFilterImageLimits.validate(pixelWidth: 1080, pixelHeight: 1350))
    }

    func testAcceptsAFullResolutionPhoneCamera() {
        // ~48 MP, the largest image someone plausibly photographs a card with.
        XCTAssertNoThrow(try SharedFilterImageLimits.validate(pixelWidth: 8064, pixelHeight: 6048))
    }

    func testRejectsADecompressionBomb() {
        // A 30 000 × 30 000 PNG of flat colour is a few MB encoded — well under the
        // byte cap — and ~3.6 GB decoded. This is the case the byte cap cannot see.
        XCTAssertThrowsError(
            try SharedFilterImageLimits.validate(pixelWidth: 30_000, pixelHeight: 30_000)
        ) { error in
            XCTAssertEqual(error as? SharedFilterImageLimits.Rejection, .tooManyPixels)
        }
    }

    func testRejectsPixelCountJustOverTheCap() {
        let cap = SharedFilterImageLimits.maximumPixelCount
        XCTAssertNoThrow(try SharedFilterImageLimits.validate(pixelWidth: cap, pixelHeight: 1))
        XCTAssertThrowsError(
            try SharedFilterImageLimits.validate(pixelWidth: cap + 1, pixelHeight: 1)
        ) { error in
            XCTAssertEqual(error as? SharedFilterImageLimits.Rejection, .tooManyPixels)
        }
    }

    func testRejectsNonPositiveDimensions() {
        for (width, height) in [(0, 100), (100, 0), (-1, 100), (100, -1), (0, 0)] {
            XCTAssertThrowsError(
                try SharedFilterImageLimits.validate(pixelWidth: width, pixelHeight: height)
            ) { error in
                XCTAssertEqual(
                    error as? SharedFilterImageLimits.Rejection,
                    .unreadableDimensions,
                    "\(width)×\(height) should be unreadable, not merely oversized."
                )
            }
        }
    }

    /// The dimensions come from an untrusted file header, so the product must not be
    /// allowed to wrap into a small positive number and pass the cap.
    func testOverflowingDimensionsAreRejectedRatherThanWrapping() {
        XCTAssertThrowsError(
            try SharedFilterImageLimits.validate(pixelWidth: Int.max, pixelHeight: 2)
        ) { error in
            XCTAssertEqual(error as? SharedFilterImageLimits.Rejection, .tooManyPixels)
        }
        XCTAssertThrowsError(
            try SharedFilterImageLimits.validate(pixelWidth: Int.max, pixelHeight: Int.max)
        ) { error in
            XCTAssertEqual(error as? SharedFilterImageLimits.Rejection, .tooManyPixels)
        }
    }

    // MARK: Detection edge

    func testDetectionEdgeStaysWellUnderThePixelCap() {
        // A bitmap bounded by the detection edge must be far inside the pixel cap,
        // or the two rules would be in tension and the tighter one would be moot.
        let bounded = SharedFilterImageLimits.maximumDetectionEdge
            * SharedFilterImageLimits.maximumDetectionEdge
        XCTAssertLessThan(bounded, SharedFilterImageLimits.maximumPixelCount)
    }
}
