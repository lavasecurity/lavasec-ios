import XCTest

@testable import LavaSecCore

final class ChainedStartupCrashLoopPolicyTests: XCTestCase {
    private typealias Policy = ChainedStartupCrashLoopPolicy

    // MARK: - The threshold

    /// Two unclean terminations tolerated, the third excludes. Asserted as a walk rather than a
    /// jump to the threshold, because the interesting failure is an off-by-one at the boundary and
    /// only the step-by-step reading distinguishes "excludes on the third" from "excludes on the
    /// second" or "on the fourth".
    func testThreeConsecutiveUncleanTerminationsExcludeTheDeviceAndTwoDoNot() {
        var state = Policy.State.clean
        XCTAssertFalse(state.hasTripped)

        state = Policy.unprovenExitDetected(in: state)
        XCTAssertEqual(state.consecutiveUnprovenExits, 1)
        XCTAssertFalse(state.hasTripped, "one unclean termination excluded the device")

        state = Policy.unprovenExitDetected(in: state)
        XCTAssertEqual(state.consecutiveUnprovenExits, 2)
        XCTAssertFalse(state.hasTripped, "two unclean terminations excluded the device")

        state = Policy.unprovenExitDetected(in: state)
        XCTAssertEqual(state.consecutiveUnprovenExits, 3)
        XCTAssertTrue(state.hasTripped, "the third unclean termination did not exclude the device")
    }

    /// The threshold is the constant, not a literal repeated in the test.
    ///
    /// Derived, so that raising the threshold cannot leave this suite asserting the old number —
    /// which would be a test agreeing with itself rather than with the policy.
    func testExclusionHappensExactlyAtTheDeclaredThreshold() {
        var state = Policy.State.clean
        for step in 1..<Policy.consecutiveUnprovenExitsBeforeTrip {
            state = Policy.unprovenExitDetected(in: state)
            XCTAssertFalse(
                state.hasTripped,
                "excluded after \(step) of \(Policy.consecutiveUnprovenExitsBeforeTrip)")
        }
        state = Policy.unprovenExitDetected(in: state)
        XCTAssertTrue(state.hasTripped, "not excluded at the declared threshold")
    }

    // MARK: - The streak

    /// A clean session breaks the streak, which is the whole difference between a streak and a
    /// lifetime total. Two unclean, one clean, two unclean must NOT exclude — four unclean
    /// terminations in a device's history, and still eligible.
    func testACleanSessionBreaksTheStreakSoATotalCannotAccumulate() {
        var state = Policy.State.clean
        state = Policy.unprovenExitDetected(in: state)
        state = Policy.unprovenExitDetected(in: state)
        XCTAssertEqual(state.consecutiveUnprovenExits, 2)

        state = Policy.cleanTeardownObserved(in: state)
        XCTAssertEqual(state.consecutiveUnprovenExits, 0, "the clean session did not reset")

        state = Policy.unprovenExitDetected(in: state)
        state = Policy.unprovenExitDetected(in: state)
        XCTAssertFalse(
            state.hasTripped,
            "four unclean terminations across a clean session excluded the device, so this is "
                + "counting a lifetime total rather than a streak")
    }

    /// A clean session must NOT lift an existing exclusion.
    ///
    /// The load-bearing case, and the one a derived `hasTripped` gets wrong: an excluded device
    /// runs DNS-only, DNS-only sessions end cleanly, so a derived flag would clear the exclusion
    /// on the first clean session — the exclusion undoing itself through its own success.
    func testACleanSessionDoesNotLiftAnExclusion() {
        var state = Policy.State.clean
        for _ in 0..<Policy.consecutiveUnprovenExitsBeforeTrip {
            state = Policy.unprovenExitDetected(in: state)
        }
        XCTAssertTrue(state.hasTripped)

        state = Policy.cleanTeardownObserved(in: state)
        XCTAssertTrue(
            state.hasTripped,
            "a clean session lifted the exclusion, so an excluded device un-excludes itself by "
                + "running the DNS-only sessions the exclusion put it in")
    }

    // MARK: - Once excluded

    /// Further unclean terminations neither advance the counter nor change the answer.
    ///
    /// Not merely tidiness: an excluded device does not start chained sessions, so a later unclean
    /// termination belongs to some other fault, and letting it advance this counter would attribute
    /// an unrelated death to chained mode.
    func testAnExcludedDeviceStopsCountingUncleanTerminations() {
        var state = Policy.State.clean
        for _ in 0..<Policy.consecutiveUnprovenExitsBeforeTrip {
            state = Policy.unprovenExitDetected(in: state)
        }
        let atExclusion = state

        state = Policy.unprovenExitDetected(in: state)
        state = Policy.unprovenExitDetected(in: state)

        XCTAssertEqual(
            state, atExclusion,
            "an excluded device kept counting, so an unrelated tunnel death is being attributed "
                + "to chained mode")
    }

    // MARK: - Re-enabling

    /// The user's re-enable clears BOTH, so the device gets a full three strikes again.
    ///
    /// Clearing only the flag would leave the counter at the threshold, and the next single
    /// unclean termination would exclude the device again — one strike, not three, with nothing
    /// user-visible to explain why it switched itself off immediately.
    func testUserReEnablingRestoresTheFullTolerance() {
        var state = Policy.State.clean
        for _ in 0..<Policy.consecutiveUnprovenExitsBeforeTrip {
            state = Policy.unprovenExitDetected(in: state)
        }
        XCTAssertTrue(state.hasTripped)

        state = Policy.explicitRetryRequested(from: state)
        XCTAssertFalse(state.hasTripped, "the re-enable did not lift the exclusion")
        XCTAssertEqual(state.consecutiveUnprovenExits, 0)

        // The proof that the tolerance is genuinely full: one more unclean termination must not
        // re-exclude. Asserting only the cleared fields above would pass against a re-enable that
        // cleared the flag and left the counter.
        state = Policy.unprovenExitDetected(in: state)
        XCTAssertFalse(
            state.hasTripped,
            "one unclean termination after a re-enable excluded the device again, so the "
                + "re-enable restored the flag but not the tolerance")
    }

    // MARK: - Shape

    /// The counter cannot be driven negative by a decoded or hand-built value.
    ///
    /// `State` is `Codable` and read from persistence written by an earlier build, so a
    /// nonsensical value is reachable without any code path producing it.
    func testANegativeCountIsClampedRatherThanTrusted() {
        let state = Policy.State(consecutiveUnprovenExits: -5, hasTripped: false)
        XCTAssertEqual(state.consecutiveUnprovenExits, 0)
        XCTAssertEqual(
            Policy.remainingAttempts(in: state),
            Policy.consecutiveUnprovenExitsBeforeTrip)
    }

    /// The clamp must hold on the DECODE path specifically, not just the initializer.
    ///
    /// The synthesized `Decodable` writes stored properties directly, so without a custom
    /// decoding path a persisted `-5` produces a state the initializer forbids — and
    /// `remainingAttempts` then reports threshold-plus-five, silently widening the tolerance
    /// the founder set at three. Decoding from JSON bytes is the exact route persistence takes.
    func testAPersistedNegativeCountIsNormalizedAtDecode() throws {
        let json = Data(#"{"consecutiveUncleanTerminations":-5,"isExcluded":false}"#.utf8)
        let state = try JSONDecoder().decode(Policy.State.self, from: json)

        XCTAssertEqual(
            state.consecutiveUnprovenExits, 0,
            "the decode path bypassed the clamp, so persisted garbage widens the tolerance")
        XCTAssertEqual(
            Policy.remainingAttempts(in: state),
            Policy.consecutiveUnprovenExitsBeforeTrip)
    }

    /// The counter is bounded above as well, because the policy adds one to it unchecked.
    ///
    /// A persisted `Int.max` with the exclusion flag clear would trap the tunnel process inside
    /// `unprovenExitDetected` — a crash during the start that was trying to RECORD a crash.
    /// Clamped to the threshold, the value stays arithmetically safe and the next unclean
    /// termination still excludes, which is the strictest reading the garbage permits.
    func testAPersistedOversizedCountIsClampedAndDoesNotTrapTheNextStrike() throws {
        let json = Data(
            #"{"consecutiveUncleanTerminations":9223372036854775807,"isExcluded":false}"#.utf8)
        let state = try JSONDecoder().decode(Policy.State.self, from: json)

        XCTAssertEqual(
            state.consecutiveUnprovenExits,
            Policy.consecutiveUnprovenExitsBeforeTrip)
        XCTAssertEqual(Policy.remainingAttempts(in: state), 0)

        // The arithmetic the bound protects: advancing from the decoded state must not trap.
        let advanced = Policy.unprovenExitDetected(in: state)
        XCTAssertTrue(advanced.hasTripped)
    }

    /// A persisted exclusion survives decoding, which is the flag's entire job.
    ///
    /// The other decode tests all carry `"isExcluded":false`, so on their own they cannot tell
    /// a faithful decode from one that defaults the flag — and a decode that drops a stored
    /// `true` re-admits an excluded device to the jetsam thrash loop on every tunnel start,
    /// exactly the failure the persistence exists to prevent. Found as a surviving mutation:
    /// hard-coding `hasTripped: false` in the decoding path passed the entire suite.
    func testAPersistedExclusionSurvivesDecoding() throws {
        let json = Data(#"{"consecutiveUncleanTerminations":0,"isExcluded":true}"#.utf8)
        let state = try JSONDecoder().decode(Policy.State.self, from: json)

        XCTAssertTrue(
            state.hasTripped,
            "a stored exclusion was dropped at decode, so an excluded device re-enters the "
                + "thrash loop on every start")
        XCTAssertEqual(Policy.remainingAttempts(in: state), 0)

        // And the whole trip, from an actually-excluded state: encode is synthesized while
        // decode is hand-written, so symmetry is asserted rather than assumed.
        var walked = Policy.State.clean
        while !walked.hasTripped {
            walked = Policy.unprovenExitDetected(in: walked)
        }
        let restored = try JSONDecoder().decode(
            Policy.State.self, from: JSONEncoder().encode(walked))
        XCTAssertEqual(restored, walked, "an excluded state did not survive the round trip")
    }

    /// The remaining-tolerance reading the Settings copy uses tracks the counter and floors at
    /// zero once excluded, so the UI never has to re-derive the threshold.
    func testRemainingToleranceTracksTheStreakAndIsZeroOnceExcluded() {
        var state = Policy.State.clean
        XCTAssertEqual(
            Policy.remainingAttempts(in: state),
            Policy.consecutiveUnprovenExitsBeforeTrip)

        state = Policy.unprovenExitDetected(in: state)
        XCTAssertEqual(
            Policy.remainingAttempts(in: state),
            Policy.consecutiveUnprovenExitsBeforeTrip - 1)

        while !state.hasTripped {
            state = Policy.unprovenExitDetected(in: state)
        }
        XCTAssertEqual(Policy.remainingAttempts(in: state), 0)
    }

    /// Round-trips through the encoding it is actually persisted with.
    ///
    /// The mechanism's entire premise is surviving a process kill, so a `State` that cannot make
    /// the trip is a backoff that resets exactly when it is needed.
    func testStateSurvivesTheRoundTripItIsPersistedAcross() throws {
        var state = Policy.State.clean
        state = Policy.unprovenExitDetected(in: state)
        state = Policy.unprovenExitDetected(in: state)

        let restored = try JSONDecoder().decode(
            Policy.State.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(restored, state)
        // And the restored value still behaves: the third strike must still exclude.
        XCTAssertTrue(Policy.unprovenExitDetected(in: restored).hasTripped)
    }
}
