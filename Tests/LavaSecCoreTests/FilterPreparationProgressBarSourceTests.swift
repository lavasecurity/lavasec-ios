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
        let app = try readAppViewModelSource()

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

        // Both paths must YIELD between the saving-top tick and Success so the renderer observes
        // (and eases to) the 3/4 frame. The same-phase present() returns without suspending, so
        // without this sleep the two writes land in one main-actor turn and the bridge batches the
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

    // RN behavior/motion tests exercise final fill and glyph ordering. This pin
    // covers the cross-process acknowledgment at the native dismissal boundary.
    func testCurrentNativeOperationWaitsForItsRendererBeforeDismissal() throws {
        let app = try readAppViewModelSource()
        XCTAssertEqual(app.components(separatedBy: "await filterDrafts.waitForPreparationSuccessPresentation(id: preparationAttemptID)").count - 1, 2)
        XCTAssertEqual(app.components(separatedBy: "filterDrafts.beginPreparationPresentation()").count - 1, 2)
        let native = try readSource(.reactNativeAppPreparation)
        XCTAssertTrue(native.contains("currentPreparationAttemptID == id"))
        XCTAssertTrue(native.contains("drafts.acknowledgePreparationSuccess(id: id)"))
        XCTAssertTrue(native.contains("drafts.preparationReplacementEpoch == model.configurationReplacementGate.epoch"))
    }
}
