import XCTest
@testable import LavaSecKit

final class ChainedBootRecoveryPolicyTests: XCTestCase {
    private func policy(generation: UInt64 = 7) throws -> ChainedBootRecoveryPolicy {
        try XCTUnwrap(ChainedBootRecoveryPolicy(generation: generation,
            startedWithProtectedDataUnavailable: true, refusal: .deviceStateUnavailable))
    }

    private func context() -> ChainedBootRecoveryPolicy.Context {
        .init(generation: 7, lifecycleIsActive: true, refusal: .deviceStateUnavailable,
              protectedDataIsReadable: true, protectionIsWanted: true, chainingIsEnabled: true,
              onDemandIsEnabled: true, networkIsSatisfied: true, networkTransitionSerial: 1,
              physicalReadIsInFlight: false, now: 100)
    }

    private func read(_ policy: inout ChainedBootRecoveryPolicy,
                      _ context: ChainedBootRecoveryPolicy.Context,
                      file: StaticString = #filePath, line: UInt = #line) throws -> ChainedBootRecoveryPolicy.ReadToken {
        guard case .checkReadiness(let token) = policy.nextAction(context) else {
            XCTFail("Expected a readiness admission", file: file, line: line)
            throw NSError(domain: "BootRecoveryTests", code: 1)
        }
        return token
    }

    func testOnlyProtectedBootStorageRefusalsArmRecovery() {
        for refusal in [TunnelDataPathLatch.Refusal.configurationUnreadable,
                        .deviceStateUnavailable, .upstreamUnavailable] {
            XCTAssertNotNil(ChainedBootRecoveryPolicy(generation: 7,
                startedWithProtectedDataUnavailable: true, refusal: refusal))
            XCTAssertNil(ChainedBootRecoveryPolicy(generation: 7,
                startedWithProtectedDataUnavailable: false, refusal: refusal))
        }
        for refusal in [nil, .chainingDisabled, .unsupportedByBuild, .chainedSurrendered,
                        .deviceIneligible(.startupCrashLoop)] as [TunnelDataPathLatch.Refusal?] {
            XCTAssertNil(ChainedBootRecoveryPolicy(generation: 7,
                startedWithProtectedDataUnavailable: true, refusal: refusal))
        }
    }

    func testOfflineUnlockWaitsForLateConnectivityWithoutSpendingBudget() throws {
        for delay in [80.0, 300.0, 3600.0] {
            var policy = try policy()
            var current = context()
            current.networkIsSatisfied = false
            XCTAssertEqual(policy.nextAction(current), .dormant)
            XCTAssertFalse(policy.pollingIsNeeded)
            current.now += delay
            XCTAssertEqual(policy.nextAction(current), .dormant)
            XCTAssertEqual(policy.onlineWindows, 0)
            XCTAssertEqual(policy.readinessChecks, 0)
            current.networkIsSatisfied = true
            let token = try read(&policy, current)
            XCTAssertEqual(policy.onlineWindows, 1)
            XCTAssertTrue(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
            XCTAssertEqual(policy.nextAction(current), .stop)
            XCTAssertFalse(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
        }
    }

    func testLockedBootDoesNotTrustLockedPreferencesOrSpendBudget() throws {
        var policy = try policy()
        var current = context()
        current.protectedDataIsReadable = false
        current.protectionIsWanted = false
        current.chainingIsEnabled = false
        current.onDemandIsEnabled = false
        current.networkIsSatisfied = false
        for tick in 0..<1000 {
            current.now = Double(tick * 5)
            XCTAssertEqual(policy.nextAction(current), .wait)
            XCTAssertTrue(policy.pollingIsNeeded)
        }
        XCTAssertEqual(policy.readinessChecks, 0)
        XCTAssertEqual(policy.onlineWindows, 0)
        current = context()
        current.now = 5000
        let token = try read(&policy, current)
        XCTAssertTrue(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
    }

    func testStationaryDeliveredPathAtUnlockNeedsNoNewEdge() throws {
        var policy = try policy()
        var current = context()
        current.protectedDataIsReadable = false
        XCTAssertEqual(policy.nextAction(current), .wait)
        current.protectedDataIsReadable = true
        let token = try read(&policy, current)
        XCTAssertTrue(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
    }

    func testFailuresAndFenceContentionSpendLifetimeBudgetAndKeepCadence() throws {
        var policy = try policy()
        var current = context()
        for attempt in 0..<ChainedBootRecoveryPolicy.maxReadinessChecks {
            current.now = 100 + Double(attempt * 5)
            let token = try read(&policy, current)
            for _ in 0..<20 { XCTAssertEqual(policy.nextAction(current), .wait) }
            XCTAssertFalse(policy.completeReadinessCheck(current, token: token, upstreamIsReady: false))
            if attempt < 2 {
                current.now += 1
                XCTAssertEqual(policy.nextAction(current), .wait)
            }
        }
        XCTAssertEqual(policy.nextAction(current), .stop)
        XCTAssertEqual(policy.readinessChecks, 3)
        XCTAssertEqual(policy.onlineWindows, 1)
    }

    func testWindowExpiryNeedsNewEdgeAndDoesNotAuthorizeLateResult() throws {
        var policy = try policy()
        var current = context()
        let old = try read(&policy, current)
        current.now = 160
        XCTAssertEqual(policy.nextAction(current), .dormant)
        XCTAssertFalse(policy.pollingIsNeeded)
        XCTAssertFalse(policy.completeReadinessCheck(current, token: old, upstreamIsReady: true))
        current.now = 180
        for _ in 0..<100 { XCTAssertEqual(policy.nextAction(current), .dormant) }
        XCTAssertEqual(policy.onlineWindows, 1)
        current.networkIsSatisfied = false
        XCTAssertEqual(policy.nextAction(current), .dormant)
        current.networkIsSatisfied = true
        current.networkTransitionSerial += 1
        let fresh = try read(&policy, current)
        XCTAssertNotEqual(fresh.windowSerial, old.windowSerial)
        XCTAssertFalse(policy.completeReadinessCheck(current, token: old, upstreamIsReady: true))
        XCTAssertTrue(policy.completeReadinessCheck(current, token: fresh, upstreamIsReady: true))
    }

    func testBeforeExactlyAndAfterDeadlineRespectOriginalWindow() throws {
        for returnAt in [159.0, 160.0, 180.0] {
            var policy = try policy()
            var current = context()
            let old = try read(&policy, current)
            current.physicalReadIsInFlight = true
            current.now = 120
            current.networkIsSatisfied = false
            XCTAssertEqual(policy.nextAction(current), .dormant)
            XCTAssertFalse(policy.pollingIsNeeded)
            current.now = returnAt
            current.networkIsSatisfied = true
            current.networkTransitionSerial += 1
            XCTAssertEqual(policy.nextAction(current), .wait)
            XCTAssertEqual(policy.onlineWindows, returnAt < 160 ? 1 : 2)
            current.physicalReadIsInFlight = false
            let restart = policy.completeReadinessCheck(current, token: old, upstreamIsReady: true)
            XCTAssertEqual(restart, returnAt < 160)
            if returnAt >= 160 {
                let fresh = try read(&policy, current)
                XCTAssertTrue(policy.completeReadinessCheck(current, token: fresh, upstreamIsReady: true))
            }
        }
    }

    func testAnEdgeBeforeExpiryCannotReplenishAStationaryDeadline() throws {
        var policy = try policy()
        var current = context()
        let token = try read(&policy, current)
        current.physicalReadIsInFlight = true
        current.now = 120
        current.networkIsSatisfied = false
        XCTAssertEqual(policy.nextAction(current), .dormant)
        current.now = 140
        current.networkIsSatisfied = true
        current.networkTransitionSerial += 1
        XCTAssertEqual(policy.nextAction(current), .wait)
        current.now = 160
        XCTAssertEqual(policy.nextAction(current), .dormant)
        current.physicalReadIsInFlight = false
        XCTAssertFalse(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
        XCTAssertEqual(policy.nextAction(current), .dormant)
        XCTAssertEqual(policy.onlineWindows, 1)
    }

    func testWedgedSlotBoundsWindowsAndNoReadOrWorkerAccumulates() throws {
        var policy = try policy()
        var current = context()
        current.physicalReadIsInFlight = true
        for window in 1...3 {
            XCTAssertEqual(policy.nextAction(current), .wait)
            XCTAssertEqual(policy.onlineWindows, window)
            current.now += 60
            XCTAssertEqual(policy.nextAction(current), window == 3 ? .stop : .dormant)
            current.networkIsSatisfied = false
            _ = policy.nextAction(current)
            current.networkIsSatisfied = true
            current.networkTransitionSerial += 1
        }
        XCTAssertEqual(policy.readinessChecks, 0)
        XCTAssertEqual(policy.onlineWindows, 3)
        current.physicalReadIsInFlight = false
        XCTAssertEqual(policy.nextAction(current), .stop)
    }

    func testSlotDrainUsesOnePendingEdgeWithoutAnotherPathCallback() throws {
        var policy = try policy()
        var slot = ChainedBootRecoveryReadSlot()
        var current = context()
        let old = try read(&policy, current)
        XCTAssertTrue(slot.admit(old))
        current.physicalReadIsInFlight = slot.isInFlight
        current.networkIsSatisfied = false
        current.now = 120
        XCTAssertEqual(policy.nextAction(current), .dormant)
        current.now = 180
        current.networkIsSatisfied = true
        current.networkTransitionSerial += 1
        for _ in 0..<100 { XCTAssertEqual(policy.nextAction(current), .wait) }
        XCTAssertEqual(policy.onlineWindows, 2)
        XCTAssertEqual(policy.readinessChecks, 1)
        XCTAssertTrue(slot.complete(old))
        current.physicalReadIsInFlight = slot.isInFlight
        XCTAssertFalse(policy.completeReadinessCheck(current, token: old, upstreamIsReady: true))
        let fresh = try read(&policy, current)
        XCTAssertTrue(slot.admit(fresh))
        XCTAssertFalse(slot.complete(old))
        XCTAssertTrue(slot.isInFlight)
        XCTAssertFalse(policy.completeReadinessCheck(current, token: old, upstreamIsReady: true))
        XCTAssertTrue(slot.complete(fresh))
        XCTAssertTrue(policy.completeReadinessCheck(current, token: fresh, upstreamIsReady: true))
    }

    func testAnExpiredPendingWakeCannotAdmitFreshWorkWhenSlotDrains() throws {
        var policy = try policy()
        var current = context()
        let old = try read(&policy, current)
        current.physicalReadIsInFlight = true
        current.now = 120
        current.networkIsSatisfied = false
        _ = policy.nextAction(current)
        current.now = 180
        current.networkIsSatisfied = true
        current.networkTransitionSerial += 1
        _ = policy.nextAction(current)
        current.now = 240
        XCTAssertEqual(policy.nextAction(current), .dormant)
        current.physicalReadIsInFlight = false
        XCTAssertFalse(policy.completeReadinessCheck(current, token: old, upstreamIsReady: true))
        XCTAssertEqual(policy.nextAction(current), .dormant)
        XCTAssertEqual(policy.readinessChecks, 1)
    }

    func testReadSlotSurvivesSupersedingLifecycleAndRejectsDuplicateDrain() throws {
        var oldPolicy = try policy()
        var freshPolicy = try policy(generation: 8)
        var current = context()
        var slot = ChainedBootRecoveryReadSlot()
        let old = try read(&oldPolicy, current)
        XCTAssertTrue(slot.admit(old))
        current.generation = 8
        current.physicalReadIsInFlight = slot.isInFlight
        XCTAssertEqual(oldPolicy.nextAction(current), .stop)
        XCTAssertEqual(freshPolicy.nextAction(current), .wait)
        XCTAssertFalse(oldPolicy.completeReadinessCheck(current, token: old, upstreamIsReady: true))
        XCTAssertTrue(slot.complete(old))
        current.physicalReadIsInFlight = false
        let fresh = try read(&freshPolicy, current)
        XCTAssertTrue(slot.admit(fresh))
        XCTAssertFalse(slot.complete(old))
        XCTAssertTrue(slot.isInFlight)
        XCTAssertTrue(slot.complete(fresh))
        XCTAssertTrue(freshPolicy.completeReadinessCheck(current, token: fresh, upstreamIsReady: true))
    }

    func testExplicitOffDisabledChainingOrOnDemandWinsDuringReadAndDormancy() throws {
        for field in [\ChainedBootRecoveryPolicy.Context.protectionIsWanted,
                      \.chainingIsEnabled, \.onDemandIsEnabled] {
            for dormant in [false, true] {
                var policy = try policy()
                var current = context()
                if dormant { current.networkIsSatisfied = false }
                let token: ChainedBootRecoveryPolicy.ReadToken? = dormant ? nil : try read(&policy, current)
                if dormant { XCTAssertEqual(policy.nextAction(current), .dormant) }
                current[keyPath: field] = false
                XCTAssertEqual(policy.nextAction(current), .stop)
                current = context()
                XCTAssertEqual(policy.nextAction(current), .stop)
                if let token {
                    XCTAssertFalse(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
                }
            }
        }
    }

    func testStoppedSupersededOrChangedRefusalCannotRestart() throws {
        for field in 0..<3 {
            var policy = try policy()
            var current = context()
            let token = try read(&policy, current)
            if field == 0 { current.generation = 8 }
            if field == 1 { current.lifecycleIsActive = false }
            if field == 2 { current.refusal = .chainedSurrendered }
            XCTAssertFalse(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
            XCTAssertEqual(policy.nextAction(context()), .stop)
        }
    }

    func testUnreadabilityAndBadMonotonicTimeNeverAuthorizeRestart() throws {
        for time in [99.0, 160.0, Double.nan, Double.infinity] {
            var policy = try policy()
            var current = context()
            let token = try read(&policy, current)
            current.protectedDataIsReadable = false
            current.now = time
            XCTAssertFalse(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
        }
    }

    func testDurableMarkerRejectsSurrenderOrExplicitRetryDuringCredentialRead() throws {
        var policy = try policy()
        var current = context()
        let token = try read(&policy, current)
        for accepted in [ChainedStartupFailureMarker.State(reason: nil, generation: 4),
                         .init(reason: policy.refusal.logValue, generation: 4)] {
            XCTAssertTrue(policy.matchesDurableRefusal(accepted, expectedMarkerGeneration: 4))
        }
        for rejected in [ChainedStartupFailureMarker.State(reason: "chainedSurrendered", generation: 4),
                         .init(reason: nil, generation: 5),
                         .init(reason: nil, generation: 4, explicitRetryRequested: true)] {
            XCTAssertFalse(policy.matchesDurableRefusal(rejected, expectedMarkerGeneration: 4))
        }
        let staleSurrender = ChainedStartupFailureMarker.State(reason: "chainedSurrendered", generation: 4)
        current.lifecycleIsActive = policy.matchesDurableRefusal(staleSurrender, expectedMarkerGeneration: 4)
        XCTAssertFalse(policy.completeReadinessCheck(current, token: token, upstreamIsReady: true))
        XCTAssertTrue(policy.isFinished)
    }

    func testSuccessorWindowDoesNotAccelerateTheReadinessCadence() throws {
        var policy = try policy()
        var current = context()
        let first = try read(&policy, current)
        XCTAssertFalse(policy.completeReadinessCheck(current, token: first, upstreamIsReady: false))
        current.now = 159
        let second = try read(&policy, current)
        XCTAssertFalse(policy.completeReadinessCheck(current, token: second, upstreamIsReady: false))
        current.now = 159.5
        current.networkIsSatisfied = false
        XCTAssertEqual(policy.nextAction(current), .dormant)
        current.now = 160
        current.networkIsSatisfied = true
        current.networkTransitionSerial += 1
        XCTAssertEqual(policy.nextAction(current), .wait)
        XCTAssertEqual(policy.onlineWindows, 2)
        XCTAssertEqual(policy.readinessChecks, 2)
        current.now = 164
        let third = try read(&policy, current)
        XCTAssertTrue(policy.completeReadinessCheck(current, token: third, upstreamIsReady: true))
    }

    func testConfigurationOwnerRevalidationNeverAdmitsWorkAndCanRetireDormancy() throws {
        var policy = try policy()
        var current = context()
        XCTAssertTrue(policy.revalidate(current))
        XCTAssertEqual(policy.onlineWindows, 0)
        XCTAssertEqual(policy.readinessChecks, 0)
        XCTAssertTrue(policy.pollingIsNeeded)
        current.networkIsSatisfied = false
        XCTAssertEqual(policy.nextAction(current), .dormant)
        XCTAssertTrue(policy.revalidate(current))
        XCTAssertFalse(policy.pollingIsNeeded)
        current.chainingIsEnabled = false
        XCTAssertFalse(policy.revalidate(current))
        current = context()
        XCTAssertEqual(policy.nextAction(current), .stop)
    }

    func testHealthGateCanWakeAStationaryPhysicalPath() throws {
        var gate = ChainedBootRecoveryPathGate(generation: 7)
        gate.observePhysical(generation: 7, serial: 1, isSatisfied: true)
        gate.observeHealth(generation: 7, serial: 1, isSatisfied: false)
        XCTAssertFalse(gate.isSatisfied)
        gate.observeHealth(generation: 7, serial: 1, isSatisfied: true)
        XCTAssertTrue(gate.isSatisfied)
        XCTAssertEqual(gate.satisfiedTransitionSerial, 1)
        gate.observeHealth(generation: 7, serial: 1, isSatisfied: true)
        XCTAssertEqual(gate.satisfiedTransitionSerial, 1)
    }

    func testCombinedPathGateAcceptsEitherOrderAndRejectsDefaultsDuplicatesAndStaleMonitors() throws {
        for physicalFirst in [true, false] {
            var gate = ChainedBootRecoveryPathGate(generation: 7)
            XCTAssertFalse(gate.isSatisfied)
            if physicalFirst {
                gate.observePhysical(generation: 7, serial: 1, isSatisfied: true)
            } else {
                gate.observeHealth(generation: 7, serial: 1, isSatisfied: true)
            }
            XCTAssertFalse(gate.isSatisfied)
            XCTAssertEqual(gate.satisfiedTransitionSerial, 0)
            gate.observeHealth(generation: 7, serial: 1, isSatisfied: true)
            gate.observePhysical(generation: 7, serial: 1, isSatisfied: true)
            XCTAssertTrue(gate.isSatisfied)
            XCTAssertEqual(gate.satisfiedTransitionSerial, 1)
            gate.observePhysical(generation: 6, serial: 999, isSatisfied: false)
            gate.observeHealth(generation: 6, serial: 999, isSatisfied: false)
            XCTAssertTrue(gate.isSatisfied)
            gate.observePhysical(generation: 7, serial: 2, isSatisfied: true)
            XCTAssertFalse(gate.isSatisfied)
            gate.observeHealth(generation: 7, serial: 2, isSatisfied: true)
            XCTAssertTrue(gate.isSatisfied)
            XCTAssertEqual(gate.satisfiedTransitionSerial, 1)
            gate.observePhysical(generation: 7, serial: 3, isSatisfied: false)
            gate.observePhysical(generation: 7, serial: 4, isSatisfied: true)
            gate.observeHealth(generation: 7, serial: 3, isSatisfied: false)
            XCTAssertFalse(gate.isSatisfied)
            gate.observeHealth(generation: 7, serial: 4, isSatisfied: true)
            XCTAssertTrue(gate.isSatisfied)
            XCTAssertEqual(gate.satisfiedTransitionSerial, 2)
        }
    }
}
