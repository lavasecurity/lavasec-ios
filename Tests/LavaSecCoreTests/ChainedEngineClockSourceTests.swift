import XCTest

@testable import LavaSecChainedUpstream

/// Pins the one fact that makes the engine-timer-freshness guard measure the right thing.
///
/// `ChainedSessionRunner` refuses to use the engine's keys until `update_timers` has been driven
/// recently, and "recently" has to be counted on the clock the engine's own deadlines are counted
/// on. The runner reads `CLOCK_MONOTONIC`; boringtun reads `CLOCK_MONOTONIC`. Neither side can
/// assert the other's choice at compile time, and the two clocks that were candidates here are
/// not interchangeable — `CLOCK_MONOTONIC` and `CLOCK_UPTIME_RAW` read 7.5 seconds apart on the
/// machine this was written on, and they diverge further across a suspension.
///
/// The failure this catches is silent by construction: measure staleness on the wrong base and
/// the guard reads "fresh" after a suspension, every behavioural test still passes, and the one
/// case the guard exists for is the one it misses. So the pairing is asserted as text against the
/// vendored source, which is the only place the engine's choice is stated.
final class ChainedEngineClockSourceTests: XCTestCase {
    /// The engine still selects the clock the runner reads.
    ///
    /// An engine upgrade or a fork that changes this — to `CLOCK_UPTIME_RAW`, to
    /// `CLOCK_MONOTONIC_RAW`, or to `std::time::Instant` — must fail here rather than quietly
    /// desynchronise the freshness comparison from the deadlines it is protecting.
    func testTheEngineStillSelectsTheClockThisRunnerReads() throws {
        let clock = try readSource(.wireGuardCoreVendoredClock)

        // The cfg block that picks the clock for Apple platforms. Asserted as the whole
        // association rather than as the bare constant name, because `CLOCK_MONOTONIC` also
        // appears in this file's non-Apple branch — matching the identifier alone would keep
        // passing after the iOS arm was changed to something else.
        XCTAssertTrue(
            clock.contains("target_os = \"ios\""),
            "the vendored engine's clock selection no longer names iOS — re-derive which clock "
                + "ChainedSessionRunner.engineClockNanoseconds() must read")

        let appleArm = try XCTUnwrap(
            clock.range(of: #"target_os = "ios"[\s\S]*?const CLOCK_ID: ClockId = ClockId::(\w+);"#,
                        options: .regularExpression),
            "could not find the cfg arm that selects the clock for iOS")
        let selection = String(clock[appleArm])
        XCTAssertTrue(
            selection.contains("ClockId::CLOCK_MONOTONIC;"),
            "the vendored engine selects a different clock for iOS than "
                + "ChainedSessionRunner.engineClockNanoseconds() reads (CLOCK_MONOTONIC). The "
                + "freshness guard would then compare a duration against a session age counted "
                + "on another base. Selection found: \(selection)")
    }

    /// The runner's clock reads the same base the engine's does.
    ///
    /// BEHAVIOURAL, not a text pin, and it can be: two reads of the same clock land microseconds
    /// apart, while the wrong base lands a constant offset away — 7.5 seconds on the machine this
    /// was written on. A tolerance far below that offset and far above scheduling noise therefore
    /// separates them.
    ///
    /// It is sound even where the offset happens to be small: the assertion only fails when the
    /// two bases differ measurably AND the runner is reading the other one. On a platform where
    /// they agree to within the tolerance there is no divergence for the guard to get wrong.
    func testTheRunnerReadsTheEnginesClockAndNotTheBudgetClock() throws {
        let engineBase = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let runnerReading = ChainedSessionRunner.engineClockNanoseconds()
        let budgetBase = DispatchTime.now().uptimeNanoseconds

        let toleranceNanoseconds: UInt64 = 50_000_000  // 50 ms
        let driftFromEngine =
            runnerReading > engineBase ? runnerReading - engineBase : engineBase - runnerReading

        XCTAssertLessThan(
            driftFromEngine, toleranceNanoseconds,
            "the runner is not reading the clock boringtun reads. Its reading is \(driftFromEngine) "
                + "ns from CLOCK_MONOTONIC; CLOCK_UPTIME_RAW is \(budgetBase) and CLOCK_MONOTONIC "
                + "is \(engineBase). Measuring staleness on the UPTIME base — the blackhole "
                + "budget's clock, which does not advance while the system is asleep — makes the "
                + "guard read fresh after a suspension, which is exactly the case it exists for")
    }
}
