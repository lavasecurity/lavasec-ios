import XCTest

@testable import LavaSecKit

/// Behavioural tests for the chained-upstream device gate. The values below are the real
/// hardware figures the threshold was chosen to separate, so a future edit to the floor
/// that reclassifies actual devices fails here rather than in the field.
final class ChainedAvailabilityTests: XCTestCase {
    /// What a "3 GB" iPhone actually reports (firmware reserves the rest).
    private let threeGigabyteDevice: UInt64 = 2_960_000_000
    /// What a "4 GB" iPhone actually reports — iPhone XS, the oldest eligible model.
    private let fourGigabyteDevice: UInt64 = 3_890_000_000

    func testPlusOnFourGigabyteHardwareIsEligible() {
        XCTAssertTrue(
            ChainedAvailability.isEligible(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: fourGigabyteDevice,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            )
        )
        XCTAssertNil(
            ChainedAvailability.ineligibilityReason(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: fourGigabyteDevice,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            )
        )
    }

    func testThresholdSeparatesTheTwoRealHardwareClusters() {
        XCTAssertLessThan(
            threeGigabyteDevice,
            ChainedAvailability.minimumPhysicalMemoryBytes,
            "a 3 GB device must fall below the floor"
        )
        XCTAssertGreaterThan(
            fourGigabyteDevice,
            ChainedAvailability.minimumPhysicalMemoryBytes,
            "iPhone XS — the oldest eligible model — must clear the floor"
        )
    }

    func testEntitlementIsRequiredRegardlessOfHardware() {
        XCTAssertFalse(
            ChainedAvailability.isEligible(
                hasLavaSecurityPlus: false,
                physicalMemoryBytes: fourGigabyteDevice,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            )
        )
        // Even the override cannot buy the feature without the entitlement.
        XCTAssertEqual(
            ChainedAvailability.ineligibilityReason(
                hasLavaSecurityPlus: false,
                physicalMemoryBytes: fourGigabyteDevice,
                experimentalOverrideEnabled: true,
                hasStartupCrashLoopTripped: false
            ),
            .notEntitled
        )
    }

    func testSubFloorHardwareIsIneligibleUntilTheOverrideOptsItIn() {
        XCTAssertEqual(
            ChainedAvailability.ineligibilityReason(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: threeGigabyteDevice,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            ),
            .insufficientMemory
        )
        // The override term must be honoured by the same predicate the latch uses, or a
        // device that opted in would restart straight back into DNS-only.
        XCTAssertTrue(
            ChainedAvailability.isEligible(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: threeGigabyteDevice,
                experimentalOverrideEnabled: true,
                hasStartupCrashLoopTripped: false
            )
        )
    }

    func testJetsamExclusionOverridesAnOtherwiseEligibleDevice() {
        for override in [false, true] {
            XCTAssertEqual(
                ChainedAvailability.ineligibilityReason(
                    hasLavaSecurityPlus: true,
                    physicalMemoryBytes: fourGigabyteDevice,
                    experimentalOverrideEnabled: override,
                    hasStartupCrashLoopTripped: true
                ),
                .startupCrashLoop,
                "an excluded device must stay excluded — restarting it into the configuration "
                    + "the backoff just excluded is the thrash loop the net exists to break"
            )
        }
    }

    func testReasonOrderReportsTheMostDurableCauseFirst() {
        // Free, sub-floor, and excluded all at once: report the entitlement, so the user is
        // not sent chasing a hardware or backoff problem they cannot act on.
        XCTAssertEqual(
            ChainedAvailability.ineligibilityReason(
                hasLavaSecurityPlus: false,
                physicalMemoryBytes: threeGigabyteDevice,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: true
            ),
            .notEntitled
        )
    }

    func testBaseCheckExcludesTheJetsamTermByDesign() {
        // The base check is the hardware/tier question only; the latch and the toggle add
        // the exclusion term. Keeping them separate is what lets the Phase-4 backoff make an
        // otherwise-eligible device ineligible without rewriting the hardware rule.
        XCTAssertTrue(
            ChainedAvailability.satisfiesBaseCheck(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: fourGigabyteDevice,
                experimentalOverrideEnabled: false
            )
        )
        XCTAssertFalse(
            ChainedAvailability.isEligible(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: fourGigabyteDevice,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: true
            )
        )
    }

    func testExactlyAtTheFloorIsEligible() {
        XCTAssertTrue(
            ChainedAvailability.isEligible(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: ChainedAvailability.minimumPhysicalMemoryBytes,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            ),
            "the floor is inclusive"
        )
        XCTAssertEqual(
            ChainedAvailability.ineligibilityReason(
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: ChainedAvailability.minimumPhysicalMemoryBytes - 1,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false
            ),
            .insufficientMemory
        )
    }
}
