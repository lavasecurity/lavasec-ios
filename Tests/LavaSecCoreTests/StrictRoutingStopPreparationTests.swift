import XCTest
@testable import LavaSecKit

@MainActor
final class StrictRoutingStopPreparationTests: XCTestCase {
    private enum Failure: Error { case save, reload }

    func testSuccessfulSaveMustBeFollowedByPreferencesReadback() async throws {
        var events: [String] = []
        try await StrictRoutingStopPreparation.perform(
            clearAndSave: { events.append("save") },
            reloadAndRead: {
                events.append("reload")
                return .init(onDemandEnabled: false, includesAllNetworks: false)
            })
        XCTAssertEqual(events, ["save", "reload"])
    }

    func testSaveFailureDoesNotConsultAnOlderSafeSnapshot() async {
        var didRead = false
        do {
            try await StrictRoutingStopPreparation.perform(
                clearAndSave: { throw Failure.save },
                reloadAndRead: {
                    didRead = true
                    return .init(onDemandEnabled: false, includesAllNetworks: false)
                })
            XCTFail("A previous safe snapshot cannot make a failed save successful")
        } catch Failure.save {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(didRead)
    }

    func testReadFailureCannotAcceptAnInMemoryClearedProfile() async {
        var memoryStrict = true
        do {
            try await StrictRoutingStopPreparation.perform(
                clearAndSave: { memoryStrict = false },
                reloadAndRead: { throw Failure.reload })
            XCTFail("A successful save callback alone is insufficient")
        } catch Failure.reload {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(memoryStrict)
    }

    func testEitherRemainingSavedFlagRefusesDisarm() async {
        for saved in [
            StrictRoutingStopPreparation.SavedState(onDemandEnabled: true, includesAllNetworks: false),
            .init(onDemandEnabled: false, includesAllNetworks: true),
            .init(onDemandEnabled: true, includesAllNetworks: true)
        ] {
            do {
                try await StrictRoutingStopPreparation.perform(
                    clearAndSave: {}, reloadAndRead: { saved })
                XCTFail("Still-armed readback must enter stop recovery: \(saved)")
            } catch StrictRoutingStopPreparation.VerificationError.profileStillArmed {
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMissingProtocolIsUnknownRatherThanStrictFalse() async {
        do {
            try await StrictRoutingStopPreparation.perform(
                clearAndSave: {},
                reloadAndRead: { .init(onDemandEnabled: false, includesAllNetworks: nil) })
            XCTFail("An unreadable profile cannot be reported as disarmed")
        } catch StrictRoutingStopPreparation.VerificationError.unreadableProtocol {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRetrySavesAgainEvenWhenFirstAttemptChangedMemory() async throws {
        var memoryStrict = true
        var savedStrict = true
        var saves = 0
        let save: @MainActor () async throws -> Void = {
            saves += 1
            memoryStrict = false
            if saves == 1 { throw Failure.save }
            savedStrict = memoryStrict
        }
        let reload: @MainActor () async throws -> StrictRoutingStopPreparation.SavedState = {
            .init(onDemandEnabled: false, includesAllNetworks: savedStrict)
        }
        do {
            try await StrictRoutingStopPreparation.perform(clearAndSave: save, reloadAndRead: reload)
            XCTFail("First save should fail")
        } catch Failure.save {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(memoryStrict)
        XCTAssertTrue(savedStrict)
        try await StrictRoutingStopPreparation.perform(clearAndSave: save, reloadAndRead: reload)
        XCTAssertEqual(saves, 2)
        XCTAssertFalse(savedStrict)
    }

    func testOnlyExplicitOffRequestsStrictRelaxationBeforeStopping() throws {
        let source = try readSource(.appViewModelProtectionLifecycle)
        let stop = try sourceBlock(in: source, startingAt: "func disableProtection(operationID:",
                                   endingBefore: "func reconnectProtectionNow")
        let prepare = try XCTUnwrap(stop.range(of: "on: manager, clearsStrictRouting: persistsExplicitIntent"))
        let disconnect = try XCTUnwrap(stop.range(of: "manager?.connection.stopVPNTunnel()"))
        XCTAssertLessThan(prepare.lowerBound, disconnect.lowerBound)
        XCTAssertTrue(stop.contains("var mustForceRemoveProfile = !onDemandDisabled"))
        let reconnect = try sourceBlock(in: source, startingAt: "func reconnectProtectionNow",
                                        endingBefore: "func waitForProtectionToConnect")
        XCTAssertFalse(reconnect.contains("clearsStrictRouting:"))
        XCTAssertFalse(reconnect.contains("includeAllNetworks = false"))
    }
}
