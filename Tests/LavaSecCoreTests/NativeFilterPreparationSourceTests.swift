import XCTest

/// Pins only native/RN route ownership. RN tests execute accessibility and recovery.
final class NativeFilterPreparationSourceTests: XCTestCase {
    func testPreparationUsesItsOperationIdentityAndNativeRecoveryOwner() throws {
        let source = try readSource(.reactNativeAppPreparation)
        XCTAssertTrue(source.contains("drafts.preparationPresentation.id"))
        XCTAssertTrue(source.contains("canReadPresentation(.appUnlock), case .failed = drafts.preparationState"))
        XCTAssertTrue(source.contains("model.retryFilterPreparation()"))
        XCTAssertTrue(source.contains("model.returnToFilterEditAfterPrepareFailure()"))
        XCTAssertTrue(source.contains("model.keepCurrentFiltersAfterPrepareFailure()"))
        XCTAssertFalse(try readSource(.filterReviewFlowView).contains("struct FilterPreparationScreen"))
    }

    func testFailureRecoveryKeepsTheAdmittedAppUnlockScopeAndNativeCapabilities() throws {
        let source = try readSource(.reactNativeAppPreparation)
        let recovery = try sourceBlock(in: source, startingAt: "guard [\"preparation.retry\"", endingBefore: "publish()")
        // Every recovery continues the already-authorized native visit. A fresh
        // editing prompt here would change all four baseline recovery journeys.
        XCTAssertFalse(recovery.contains("authorize("))
        XCTAssertFalse(recovery.contains(".filterEditing"))
        XCTAssertTrue(recovery.contains("UIApplication.shared.applicationState == .active, currentPreparationAttemptID == id"))
        XCTAssertTrue(recovery.contains("canReadPresentation(.appUnlock), case .failed = drafts.preparationState"))
        XCTAssertTrue(recovery.contains("!drafts.preparationRecoveryInFlight"))
        XCTAssertTrue(recovery.contains("drafts.preparationRecoveryInFlight = true"))
        XCTAssertTrue(recovery.contains("guard preparationRetryIsAvailable"))
        XCTAssertTrue(recovery.contains("guard model.filterPreparationFailureOffersEditReturn"))
        XCTAssertTrue(recovery.contains("guard let reason = model.filterPreparationUpgradeReason"))
        XCTAssertTrue(source.contains("drafts.preparationReplacementEpoch == model.configurationReplacementGate.epoch"))
        // Initial switch/save authorization is still owned by the established
        // filter command boundary, before an attempt can create this screen.
        let filters = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(filters.contains("try await authorize(.filterEditing, \"Switch filter\", fresh: true)"))
        XCTAssertTrue(filters.contains("try await authorize(.filterEditing, saving ? \"Save filter\" : \"Edit filter\", fresh: name == \"filter.save\" || name == \"filter.delete\")"))
    }
}
