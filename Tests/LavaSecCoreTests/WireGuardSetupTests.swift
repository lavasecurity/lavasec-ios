import XCTest
@testable import LavaSecCore

final class WireGuardSetupTests: XCTestCase {
    func testSetupChoicePersistsWithoutEnablingChaining() throws {
        let value = try JSONDecoder().decode(
            AppConfiguration.self,
            from: Data(#"{"wireGuardSetupEnabled":true,"chainedUpstreamEnabled":false}"#.utf8))
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(encoded["wireGuardSetupEnabled"] as? Bool, true)
        XCTAssertFalse(value.chainedUpstreamEnabled)
    }

    func testClosingAndReopeningSetupNeverReenablesChaining() {
        var value = AppConfiguration(chainedUpstreamEnabled: true)
        XCTAssertTrue(value.wireGuardSetupEnabled)
        value.setWireGuardSetupEnabled(false)
        XCTAssertFalse(value.chainedUpstreamEnabled)
        value.setWireGuardSetupEnabled(true)
        XCTAssertTrue(value.wireGuardSetupEnabled)
        XCTAssertFalse(value.chainedUpstreamEnabled)
    }

    func testLegacyEnabledConfigurationKeepsItsRequestAndOpensSetup() throws {
        let value = try JSONDecoder().decode(
            AppConfiguration.self, from: Data(#"{"chainedUpstreamEnabled":true}"#.utf8))
        XCTAssertTrue(value.wireGuardSetupEnabled)
        XCTAssertTrue(value.chainedUpstreamEnabled)
        let fresh = try JSONDecoder().decode(AppConfiguration.self, from: Data("{}".utf8))
        XCTAssertFalse(fresh.wireGuardSetupEnabled)
        XCTAssertFalse(fresh.chainedUpstreamEnabled)
    }

    func testOpeningSetupRequiresBothCredentialHalvesBeforeEnabling() {
        var inputs = ChainedSurfaceInputs(hasEntitlement: true, preferenceEnabled: false,
                                         hasStoredConfiguration: false)
        XCTAssertEqual(ChainedSetupPolicy.configurationIssue(inputs), .missingConfiguration)
        XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
        inputs.hasStoredConfiguration = true
        inputs.storedConfigurationIsMissingKey = true
        XCTAssertEqual(ChainedSetupPolicy.configurationIssue(inputs), .missingPrivateKey)
        XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
        inputs.storedConfigurationIsMissingKey = false
        XCTAssertNil(ChainedSetupPolicy.configurationIssue(inputs))
        XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: false, inputs: inputs))
        XCTAssertTrue(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
    }

    func testUnknownNeverBecomesMissingEvenWhenBothHalvesCouldNotBeRead() {
        let inputs = ChainedSurfaceInputs(hasEntitlement: true, preferenceEnabled: true,
                                         storeIsUnreadable: true, hasStoredConfiguration: false,
                                         storedConfigurationIsMissingKey: true)
        XCTAssertEqual(ChainedSetupPolicy.configurationIssue(inputs), .unavailable)
        XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
        // Classification is read-only: it cannot silently withdraw the stored request.
        XCTAssertTrue(inputs.preferenceEnabled)
    }

    func testUsableCredentialsStillRequireEntitlementAndDeviceEligibility() {
        var inputs = ChainedSurfaceInputs(hasEntitlement: false, preferenceEnabled: false)
        XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
        inputs.hasEntitlement = true
        inputs.deviceStateIsUnreadable = true
        XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
        inputs.deviceStateIsUnreadable = false
        for reason in [ChainedAvailability.Ineligibility.insufficientMemory, .notEntitled] {
            inputs.ineligibility = reason
            XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
        }
        inputs.ineligibility = nil
        inputs.isSurrenderSuppressed = true
        XCTAssertTrue(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
    }

    func testConfigurationRepairAndSelectionRemainAvailableAfterAStartupFailure() {
        var inputs = ChainedSurfaceInputs(hasEntitlement: true, preferenceEnabled: true,
                                         ineligibility: .startupCrashLoop, hasStoredConfiguration: false)
        XCTAssertTrue(ChainedSetupPolicy.canEditConfiguration(inputs))
        XCTAssertFalse(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
        inputs.hasStoredConfiguration = true
        XCTAssertTrue(ChainedSetupPolicy.canEnable(setupEnabled: true, inputs: inputs))
    }

    func testMissingConfigurationOutranksAnOldForwardingFailureForRecovery() {
        let inputs = ChainedSurfaceInputs(hasEntitlement: true, preferenceEnabled: true,
                                         ineligibility: .startupCrashLoop,
                                         isSurrenderSuppressed: true, hasStoredConfiguration: false)
        XCTAssertEqual(ChainedSetupPolicy.configurationIssue(inputs), .missingConfiguration)
    }
}
