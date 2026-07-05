import XCTest

/// Source guardrails for the recompile progress bar's "equal quarters + smooth fill" presentation.
///
/// The bar is divided into four equal steps — Downloading, Compiling, Saving, and the terminal
/// Success — so each visible step advances a consistent quarter and the final Success fill is a
/// quarter, not a jump. The bar also eases between steps (a smooth visual, not a hard jump), and
/// Success sweeps the bar to a full 100% before the checkmark takes over. The quarter *math* is
/// covered by `FilterPreparationPresentationPolicyTests`; these pin the app-side wiring as text
/// (the app target sits outside the SPM test target). Rendered motion is a device-QA check.
final class FilterPreparationProgressBarSourceTests: XCTestCase {

    // MARK: Saving fills its quarter before Success (no frozen tail → jump)

    func testApplyLandsSavingOnItsQuarterTopBeforeSuccess() throws {
        let app = try readSource(.appViewModel)

        // The presenter maps phases to equal quarters (Success owns the 4th).
        XCTAssertTrue(
            app.contains("FilterPreparationPresentationPolicy.equalStepsProgress(phase: update.phase, rawProgress: update.progress)"),
            "The presenter must map each phase through equalStepsProgress (equal quarters), not equal thirds.")

        // Both apply paths (draft-apply + user switch) must tick Saving to the TOP of its quarter
        // (rawProgress 1.0 → 3/4) once persist + tunnel reload finish, so the terminal Success step
        // is a clean final quarter and the persist/reload tail is not a frozen bar that then jumps.
        XCTAssertEqual(
            app.components(separatedBy: "FilterPreparationProgressUpdate(progress: 1.0, phase: .saving)").count - 1, 2,
            "Both apply paths must land the bar on the saving quarter top (progress 1.0, .saving) before setting Success.")

        // Success is still the explicit terminal step at 100% (the 4th quarter's end).
        XCTAssertEqual(
            app.components(separatedBy: "filterPreparationState = .preparing(progress: 1, message: \"Success\")").count - 1, 2,
            "Both apply paths must set the terminal Success step at full progress.")

        // Both paths must YIELD between the saving-top tick and Success so SwiftUI actually renders
        // (and eases to) the 3/4 frame. The same-phase present() returns without suspending, so
        // without this sleep the two writes land in one main-actor turn and SwiftUI coalesces the
        // 3/4 state away — the bar would sweep straight from the previous saving value to 100%.
        var searchStart = app.startIndex
        for label in ["draft-apply", "switch"] {
            let tick = try XCTUnwrap(
                app.range(of: "FilterPreparationProgressUpdate(progress: 1.0, phase: .saving)", range: searchStart..<app.endIndex),
                "missing saving-top tick for the \(label) path")
            let success = try XCTUnwrap(
                app.range(of: "filterPreparationState = .preparing(progress: 1, message: \"Success\")", range: tick.upperBound..<app.endIndex),
                "missing Success after the saving-top tick (\(label))")
            // A render yield must sit strictly BETWEEN this path's tick and its Success.
            XCTAssertNotNil(
                app.range(of: "try? await Task.sleep(nanoseconds: 500_000_000)", range: tick.upperBound..<success.lowerBound),
                "The saving-top tick must be followed by a render yield before Success so the 3/4 frame is not coalesced away (\(label)).")
            // ...and an ownership recheck must sit between the tick and Success too: the render yield
            // is a suspension, so a stale (superseded) task must bail before the Success confirmation
            // rather than clobber the newer preparation's shared cover.
            XCTAssertNotNil(
                app.range(of: "guard configurationReplacementGate.isCurrent", range: tick.upperBound..<success.lowerBound),
                "A supersession recheck must sit between the saving-top tick and Success so a superseded apply doesn't clobber the newer cover (\(label)).")
            searchStart = success.upperBound
        }
    }

    // MARK: The cover sweeps the bar to full, then reveals the checkmark

    func testSuccessFillsToFullThenRevealsCheckmark() throws {
        let block = try sourceBlock(
            in: try readSource(.filterReviewFlowView),
            startingAt: "struct FilterPreparationScreen: View {",
            endingBefore: "struct PreparationTickerTitle: View {"
        )

        // The checkmark is gated on a reveal flag driven AFTER the fill, so the bar fills to a full
        // 100% first (Success reads as the bar completing, not vanishing at 3/4).
        XCTAssertTrue(block.contains("@State private var successGlyphShown = false"),
                      "The cover needs a reveal flag so the checkmark waits for the fill sweep.")
        XCTAssertTrue(block.contains("if progress >= 1, successGlyphShown {"),
                      "The checkmark must be gated on the post-fill reveal flag, not shown the instant progress hits 1.")
        XCTAssertTrue(block.contains(".task(id: isTerminalSuccess)"),
                      "A task keyed on the terminal-success state must drive (and reset) the checkmark reveal.")

        // The bar eases between steps — a smooth increase, not a jump between intervals — but the
        // ease MUST route through LavaFlowTransition.incidental(reduceMotion:) so it lands instantly
        // under Reduce Motion (matching the sibling PreparationTickerTitle and the app convention).
        // Pin the gated modifier bound to `progress`, but NOT the cosmetic duration literal (that is
        // meant to be tuned).
        XCTAssertTrue(block.contains(".animation(LavaFlowTransition.incidental(") && block.contains(", value: progress)"),
                      "The progress bar must ease its fill via a LavaFlowTransition.incidental(reduceMotion:)-gated .animation(_:value: progress), so the fill lands instantly under Reduce Motion.")

        // The checkmark reveal must also honor Reduce Motion: the reveal delay collapses (no dead-hold)
        // and the reveal animation is gated. The opacity fade itself is fine to keep (a fade is motion-free).
        XCTAssertTrue(block.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"),
                      "FilterPreparationScreen must read Reduce Motion to gate the fill + reveal.")
        XCTAssertTrue(block.contains("reduceMotion ? 0 : 550_000_000"),
                      "The checkmark reveal delay must collapse to 0 under Reduce Motion so there is no full-bar dead-hold.")
        XCTAssertTrue(block.contains("withAnimation(LavaFlowTransition.incidental("),
                      "The checkmark reveal must animate through the Reduce-Motion gate too.")
    }
}
