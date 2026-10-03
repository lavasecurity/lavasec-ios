import XCTest

@testable import LavaSecKit

/// Which ineligibility causes may destroy a stored preference, and which may not.
///
/// The distinction is the whole content of this policy. Refusing to run chained mode costs
/// the user nothing — the next start re-evaluates. Clearing their flag forgets what they
/// asked for, and only they can ask again. Getting the subset wrong is silent either way:
/// too eager and a safety net deletes the setting it was protecting; too lax and Settings
/// shows a toggle that is on while nothing happens.
final class ChainedUpstreamReconcileTests: XCTestCase {
    private static let eligible = ChainedAvailability.minimumPhysicalMemoryBytes
    private static let subFloor = ChainedAvailability.minimumPhysicalMemoryBytes - 1

    func testALapsedSubscriptionClearsTheFlag() {
        XCTAssertEqual(
            ChainedAvailability.reconcile(
                chainedUpstreamEnabled: true,
                hasLavaSecurityPlus: false,
                physicalMemoryBytes: Self.eligible,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            ),
            .disable(.notEntitled)
        )
    }

    func testHardwareThatCanNeverQualifyClearsTheFlag() {
        // The device-transfer case: a configuration carried onto smaller hardware. The
        // hardware will not change, so the preference can never be honoured here.
        XCTAssertEqual(
            ChainedAvailability.reconcile(
                chainedUpstreamEnabled: true,
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: Self.subFloor,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            ),
            .disable(.insufficientMemory)
        )
    }

    func testJetsamExclusionRefusesButDoesNotClearTheFlag() {
        // The backoff marker is device-local and the user clears it. If this also cleared the
        // flag, a safety net would be quietly deleting the setting it exists to protect —
        // and the user would have to rediscover the feature rather than clear an exclusion.
        XCTAssertEqual(
            ChainedAvailability.reconcile(
                chainedUpstreamEnabled: true,
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: Self.eligible,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: true
            ),
            .noChange
        )
        // ...but the device is still ineligible, so nothing runs chained. Refusal and
        // revocation are different answers to different questions.
        XCTAssertFalse(
            ChainedAvailability.isEligible(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: Self.eligible,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: true
            )
        )
    }

    func testTheOverrideKeepsSubFloorHardwareFromBeingRevoked() {
        // A user who opted a small device in must not have that opt-in undone by the very
        // condition it exists to waive.
        XCTAssertEqual(
            ChainedAvailability.reconcile(
                chainedUpstreamEnabled: true,
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: Self.subFloor,
                experimentalOverrideEnabled: true,
                hasStartupCrashLoopTripped: false
            ),
            .noChange
        )
    }

    func testAnEligibleDeviceIsLeftAlone() {
        XCTAssertEqual(
            ChainedAvailability.reconcile(
                chainedUpstreamEnabled: true,
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: Self.eligible,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            ),
            .noChange
        )
    }

    func testAFlagThatIsAlreadyOffIsNeverAWrite() {
        // The caller runs this on every eligibility event and folds it into an existing
        // config write. If a disabled flag could still report `.disable`, the reconcile would
        // dirty the configuration on every entitlement tick for users who never touched
        // chaining — which on a pre-Phase-4 build is every user.
        for plus in [false, true] {
            for memory in [Self.subFloor, Self.eligible] {
                for excluded in [false, true] {
                    XCTAssertEqual(
                        ChainedAvailability.reconcile(
                            chainedUpstreamEnabled: false,
                            hasLavaSecurityPlus: plus,
                            physicalMemoryBytes: memory,
                            experimentalOverrideEnabled: false,
                            hasStartupCrashLoopTripped: excluded
                        ),
                        .noChange,
                        "plus=\(plus) memory=\(memory) excluded=\(excluded)"
                    )
                }
            }
        }
    }

    func testRevocationIsAStrictSubsetOfIneligibility() {
        // Stated as a property so a new Ineligibility case has to be classified deliberately:
        // the switch in revokesStoredPreference is exhaustive, so adding one fails to compile
        // until someone decides which side it falls on.
        XCTAssertTrue(ChainedAvailability.revokesStoredPreference(.notEntitled))
        XCTAssertTrue(ChainedAvailability.revokesStoredPreference(.insufficientMemory))
        XCTAssertFalse(ChainedAvailability.revokesStoredPreference(.startupCrashLoop))
    }

    func testEveryRevokingCauseIsReachableFromTheReconcile() {
        // Guards against a cause that revokes in principle but is shadowed in practice by
        // ineligibilityReason's ordering — a rule that could never fire.
        let produced: Set<ChainedAvailability.Ineligibility> = Set(
            [
                (false, Self.eligible),
                (true, Self.subFloor),
            ].compactMap { plus, memory in
                guard case .disable(let cause) = ChainedAvailability.reconcile(
                    chainedUpstreamEnabled: true,
                    hasLavaSecurityPlus: plus,
                    physicalMemoryBytes: memory,
                    experimentalOverrideEnabled: false,
                    hasStartupCrashLoopTripped: false
                ) else {
                    return nil
                }
                return cause
            }
        )

        XCTAssertEqual(produced, [.notEntitled, .insufficientMemory])
    }
}
