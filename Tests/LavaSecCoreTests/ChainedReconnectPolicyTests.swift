import XCTest

@testable import LavaSecChainedUpstream

/// The outage budget: how long the tunnel may claim traffic it cannot carry.
///
/// While a chained session is down the user has no internet at all — the tunnel holds
/// `0.0.0.0/0` and `::/0` and forwards nothing. So the failure mode here is not a crash, it
/// is a VPN that reports itself connected while the user watches a dead connection. These
/// tests are about bounding that, and about never bounding it in a way that gives up on a
/// session that was about to work.
final class ChainedReconnectPolicyTests: XCTestCase {
    private typealias Policy = ChainedReconnectPolicy

    /// Every engine error this policy must triage. Shared so the totality check and the
    /// cross-policy agreement check cannot drift apart.
    private static let allTriagedCauses: [WireGuardEngineError] = [
        .invalidArgument, .destinationBufferTooSmall, .noCurrentSession, .underLoad,
        .protocolViolation, .oversizedDatagram, .connectionExpired, .engineInternal,
        .packetTooLarge, .sessionCreationFailed, .unrecognized(code: -1),
    ]

    /// Builds a session-end cause the only way the tunnel can: classify the engine error with
    /// the data-path policy, then take what it hands over.
    ///
    /// Tests must not construct one any other way. Doing so would exercise a route the packet
    /// loop does not have, which is precisely the mistake that let the two policies disagree —
    /// the old tests called the reconnect policy with bare engine errors the data path would
    /// never have escalated.
    private static func sessionEnd(
        _ error: WireGuardEngineError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChainedSessionEndCause {
        try XCTUnwrap(
            ChainedSessionEndCause(ChainedDataPathPolicy.action(for: .failure(error))),
            "\(error) is a per-packet verdict — it never reaches the reconnect policy",
            file: file, line: line
        )
    }

    private func decide(
        attempts: Int = 0,
        elapsed: Int = 0,
        cause: WireGuardEngineError = .connectionExpired,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChainedReconnectDecision {
        Policy.decision(
            completedAttempts: attempts,
            elapsedSeconds: elapsed,
            cause: try Self.sessionEnd(cause, file: file, line: line)
        )
    }

    // MARK: - The budget is real and finite

    func testTheOutageIsBoundedRatherThanRetryingForever() throws {
        // Walk the schedule the way the tunnel would, accumulating real elapsed time.
        var elapsed = 0
        var attempts = 0
        var decisions: [ChainedReconnectDecision] = []

        while attempts < 20 {
            let decision = try decide(attempts: attempts, elapsed: elapsed)
            decisions.append(decision)
            guard case .retry(let seconds, _, _) = decision else { break }
            elapsed += seconds
            attempts += 1
        }

        XCTAssertTrue(
            decisions.last?.surrendersChaining == true,
            "the schedule must terminate in a fallback, not run out of the loop"
        )
        XCTAssertLessThanOrEqual(
            elapsed,
            Policy.maximumBlackholeSeconds,
            "the tunnel held traffic it could not carry for longer than the budget allows"
        )
    }

    func testTheBudgetIsCheckedAgainstTheDelayAboutToBeSpent() throws {
        // Waiting past the deadline to discover we are past it is the same mistake in
        // slower motion. With 14s spent and a 2s delay pending, 16 > 15, so surrender now.
        XCTAssertEqual(
            try decide(attempts: 1, elapsed: 14),
            .fallBackToDNSOnly(reason: .budgetExhausted)
        )
    }

    func testAFallbackIsNotAFailureStateAndIsReachedPromptly() {
        // DNS-only still filters and still has working internet, so reaching it quickly is
        // the desirable outcome, not a last resort. Bound the wall-clock explicitly.
        XCTAssertLessThanOrEqual(Policy.maximumBlackholeSeconds, 20)
    }

    // MARK: - Retrying quickly, then backing off

    func testTheFirstRetryIsImmediateEnoughForANetworkTransition() throws {
        // The common cause is a handoff where the peer is reachable again almost at once.
        XCTAssertEqual(try decide(), .retry(afterSeconds: 1, attempt: 1, attemptDeadlineSeconds: 14))
    }

    func testDelaysGrowSoAnUnreachablePeerIsNotHammered() {
        let delays = (1...5).map(Policy.delaySeconds(forAttempt:))
        XCTAssertEqual(delays, [1, 2, 4, 8, 16])
        XCTAssertEqual(delays, delays.sorted(), "backoff must be monotonic")
    }

    func testDelaysAreDefinedForNonsensicalAttemptNumbers() {
        // Defensive: a caller-side off-by-one must not produce a zero or negative delay,
        // which would spin the reconnect loop at full speed.
        for attempt in [Int.min, -1, 0] {
            XCTAssertGreaterThanOrEqual(Policy.delaySeconds(forAttempt: attempt), 1)
        }
        XCTAssertGreaterThanOrEqual(Policy.delaySeconds(forAttempt: Int.max), 1, "must not overflow")
    }

    func testNegativeElapsedIsTreatedAsNoTimeSpent() throws {
        XCTAssertEqual(try decide(attempts: 0, elapsed: -100), .retry(afterSeconds: 1, attempt: 1, attemptDeadlineSeconds: 14))
    }

    // MARK: - Causes that no retry can fix

    func testAnUnusableEngineSurrendersWithoutSpendingTheBudget() throws {
        // A poisoned lock or an unrecognized status is a fault in the object, not the
        // network. Retrying burns the user's connectivity on an operation that cannot
        // succeed.
        // engineInternal deliberately NOT here: a poisoned lock is cleared by a fresh
        // session, so ChainedDataPathPolicy classifies it as `.reconnect` and this policy
        // honours that. See testAPoisonedLockEarnsAnotherAttemptButADeterministicFaultDoesNot.
        for cause in [
            WireGuardEngineError.unrecognized(code: -99),
            .sessionCreationFailed,
        ] {
            XCTAssertEqual(
                try decide(cause: cause),
                .fallBackToDNSOnly(reason: .engineUnusable),
                "\(cause) must not consume a retry"
            )
        }
    }

    func testAnExpiredSessionIsWorthRetrying() throws {
        // The ordinary case: rekey missed its window, and a fresh handshake usually works.
        XCTAssertEqual(
            try decide(cause: .connectionExpired),
            .retry(afterSeconds: 1, attempt: 1, attemptDeadlineSeconds: 14))
    }

    func testEveryCauseResolvesToADecision() {
        // A new engine error must not silently acquire retry semantics by falling into a
        // default branch.
        //
        // Since `decision` takes a ChainedSessionEndCause, totality is now two questions, and
        // both are asked here: every engine error must be CLASSIFIED by the data-path policy,
        // and every error that classification escalates must resolve to a decision. Asking
        // only the second would let a new error that the data path silently drops look
        // covered.
        let causes = Self.allTriagedCauses
        for cause in causes {
            let action = ChainedDataPathPolicy.action(for: .failure(cause))
            guard let ending = ChainedSessionEndCause(action) else {
                // Classified, and classified as something that never ends a session. That is a
                // complete answer for this cause, but only if the classifier really produced a
                // per-packet verdict rather than falling through to some non-error action.
                guard case .dropPacket = action else {
                    return XCTFail("\(cause) classified as \(action.logValue), neither a session "
                        + "end nor a per-packet drop")
                }
                continue
            }
            switch Policy.decision(completedAttempts: 0, elapsedSeconds: 0, cause: ending) {
            case .retry, .fallBackToDNSOnly:
                continue
            }
        }
        // A hand-maintained count is a weak guard — it catches a case added to the engine
        // enum without being triaged here, which is the realistic mistake, but it cannot
        // catch a case listed twice. `.oversizedDatagram` was added to the production switch
        // two commits ago and missed here, and the switch being exhaustive kept it green.
        XCTAssertEqual(causes.count, 11, "an engine error was added without triaging it here")
        XCTAssertEqual(Set(causes.map(String.init(describing:))).count, causes.count,
                       "a cause is listed twice, so the count proves less than it looks")
    }

    // MARK: - Logging

    func testDecisionsNameThemselvesForAFieldLog() throws {
        XCTAssertEqual(try decide().logValue, "retry-1-in-1s-deadline-14s")
        XCTAssertEqual(
            try decide(cause: .sessionCreationFailed).logValue,
            "fall-back-dns-only-engineUnusable"
        )
        XCTAssertEqual(
            try decide(attempts: 9, elapsed: 999).logValue,
            "fall-back-dns-only-budgetExhausted"
        )
        // The two surrenders must be distinguishable: one is our engine failing, the other
        // is the peer being unreachable, and they lead to different investigations.
        XCTAssertNotEqual(
            try decide(cause: .engineInternal).logValue,
            try decide(attempts: 9, elapsed: 999).logValue
        )
    }
    // MARK: - The budget bounds the outage, not just the pauses between attempts

    func testARetryNeverAuthorizesMoreThanTheRemainingBudget() throws {
        // The regression this exists for: the policy is only consulted when a session ENDS,
        // but boringtun retransmits a handshake for REKEY_ATTEMPT_TIME (90 s) before it
        // yields connectionExpired. Budgeting only the delays bounded the pauses BETWEEN
        // attempts while leaving the attempts themselves unbounded, so a 15 s budget
        // permitted roughly a 91 s blackhole. Every retry now carries the deadline that
        // closes it, and the caller must arm it as a timer.
        for elapsed in 0...Policy.maximumBlackholeSeconds {
            for attempts in 0...10 {
                let decision = Policy.decision(
                    completedAttempts: attempts,
                    elapsedSeconds: elapsed,
                    cause: try Self.sessionEnd(.connectionExpired)
                )
                guard case .retry(let delay, _, let deadline) = decision else { continue }
                XCTAssertLessThanOrEqual(
                    elapsed + delay + deadline,
                    Policy.maximumBlackholeSeconds,
                    "elapsed \(elapsed) + delay \(delay) + deadline \(deadline) overruns the budget"
                )
                XCTAssertGreaterThanOrEqual(
                    deadline,
                    Policy.minimumUsefulAttemptSeconds,
                    "authorized an attempt with no time left to succeed in"
                )
            }
        }
    }

    func testTheBudgetIsExhaustedRatherThanRetriedWithNoTimeLeft() throws {
        // The old guard was `elapsed + delay <= budget`, so landing exactly on the boundary
        // returned a retry with zero seconds to run in. Surrendering is the honest answer,
        // and it keeps `budgetExhausted` in a log meaning what it says.
        XCTAssertEqual(
            Policy.decision(
                completedAttempts: 0,
                elapsedSeconds: Policy.maximumBlackholeSeconds - 1,
                cause: try Self.sessionEnd(.connectionExpired)
            ),
            .fallBackToDNSOnly(reason: .budgetExhausted)
        )
    }

    func testTheDeadlineShrinksAsTheBudgetIsSpent() throws {
        // Successive attempts must get strictly less room, or it is not a budget.
        //
        // The sample points are WALKED rather than listed. A fixed list has to be re-picked every
        // time `minimumUsefulAttemptSeconds` moves — it was [0, 2, 5, 8] until the floor became 7
        // and elapsed 8 stopped authorizing anything — and a list that needs re-picking is a list
        // that encodes the constant it is meant to be independent of.
        var previous = Int.max
        var samples = 0
        for elapsed in 0...Policy.maximumBlackholeSeconds {
            guard case .retry(_, _, let deadline) = Policy.decision(
                completedAttempts: 0, elapsedSeconds: elapsed, cause: try Self.sessionEnd(.connectionExpired))
            else { break }
            XCTAssertLessThan(deadline, previous, "deadline did not shrink at elapsed \(elapsed)")
            previous = deadline
            samples += 1
        }

        XCTAssertGreaterThanOrEqual(
            samples, 3,
            "fewer than three elapsed values authorize a retry at all — the budget has collapsed "
                + "to a single attempt and this test is no longer observing a shrinking deadline")
    }

    func testHostileIntegersSurrenderRatherThanTrap() throws {
        // Swift's + and - TRAP on overflow. This is a public entry point that already
        // normalizes negatives, so it treated hostile input as in scope on one side and
        // crashed on the other — and in a Network Extension a trap is a tunnel abort, which
        // drops the user to no protection at all rather than to the DNS-only fallback this
        // type exists to reach.
        //
        // Two separate expressions overflowed. `completedAttempts: .max` trapped computing
        // the attempt number, BEFORE the budget arithmetic that the other fix covers, so
        // fixing one alone left the other live.
        for (attempts, elapsed) in [
            (Int.max, 0), (Int.max, Int.max), (Int.max - 1, 0),
            (0, Int.max), (0, Int.max - 1), (Int.min, Int.min), (Int.min, 0), (0, Int.min),
        ] {
            let decision = Policy.decision(
                completedAttempts: attempts, elapsedSeconds: elapsed, cause: try Self.sessionEnd(.connectionExpired))
            // Nothing is asserted about WHICH answer beyond the invariant that matters: a
            // budget that cannot be shown to hold must surrender, never retry.
            if case .retry(let delay, _, let deadline) = decision {
                XCTAssertLessThanOrEqual(
                    max(elapsed, 0) + delay + deadline,
                    Policy.maximumBlackholeSeconds,
                    "attempts=\(attempts) elapsed=\(elapsed) retried past the budget"
                )
            }
        }
    }

    /// The retransmit cadence `minimumUsefulAttemptSeconds` is derived from is FLAT.
    ///
    /// boringtun's own comment quotes the WireGuard paper's "REKEY_TIMEOUT + jitter ms, where
    /// jitter is some random value between 0 and 333 ms" directly above a guard that adds no
    /// jitter at all. wireguard-go implements it; boringtun does not; we run boringtun. Our
    /// policy comment repeated the paper's number for a while, which is harmless until someone
    /// reclaims 333 ms from a budget that never had it.
    ///
    /// A bump that makes the retransmit non-flat has to be noticed, because the floor stops
    /// being derivable from `REKEY_TIMEOUT` alone the moment it is.
    func testTheEngineRetransmitCadenceIsFlatWithNoJitter() throws {
        let timers = try readSource(.wireGuardCoreVendoredTimers)
        XCTAssertTrue(
            timers.contains("if time_init_sent.elapsed() >= REKEY_TIMEOUT {"),
            "the vendored engine's handshake retransmit is no longer a flat REKEY_TIMEOUT "
                + "comparison — re-derive Policy.minimumUsefulAttemptSeconds before changing this"
        )
    }

    /// The floor must clear all THREE terms of its derivation, not just `REKEY_TIMEOUT`.
    ///
    /// Derived here rather than restated, and derived from the same sources the runtime uses, so
    /// that changing the pump cadence or the engine's timeout cannot leave the constant behind:
    ///
    /// - `REKEY_TIMEOUT`, read from the vendored engine.
    /// - Clock flooring, up to a full second: `ChainedMonotonicClock.nowSeconds()` is an integer
    ///   division, so an attempt stamped at second N may really have begun at N.99, and its
    ///   watchdog still fires at N + floor.
    /// - Pump quantisation: `update_timers` is the only emitter of the retransmit and runs on
    ///   `outageTickInterval` + `outageTickLeeway`, so the retransmit lands AFTER the threshold.
    ///
    /// Six seconds cleared only the first term. Found by Codex on PR #488.
    func testTheAttemptFloorClearsFlooringAndPumpQuantisation() throws {
        let timers = try readSource(.wireGuardCoreVendoredTimers)
        let match = try XCTUnwrap(
            timers.range(
                of: #"REKEY_TIMEOUT: Duration = Duration::from_secs\((\d+)\)"#,
                options: .regularExpression),
            "REKEY_TIMEOUT is no longer declared the way this test reads it")
        let engineRetransmitSeconds = try XCTUnwrap(
            Int(timers[match].split(separator: "(").last?.dropLast() ?? ""))

        // The whole second `nowSeconds()` can discard.
        let clockFlooringSeconds = 1
        // The pump can only fire the retransmit on a tick, and a tick may be late by its leeway.
        let pumpSeconds = Self.seconds(ChainedOutageDriver.outageTickInterval)
            + Self.seconds(ChainedOutageDriver.outageTickLeeway)

        let required = Double(engineRetransmitSeconds + clockFlooringSeconds) + pumpSeconds
        XCTAssertGreaterThan(
            Double(Policy.minimumUsefulAttemptSeconds), required,
            "an attempt authorized for \(Policy.minimumUsefulAttemptSeconds)s can begin as late as "
                + "0.99s into its stamped second and be torn down before the engine's retransmit, "
                + "which needs \(required)s of real time to have been emitted")
    }

    private static func seconds(_ interval: DispatchTimeInterval) -> Double {
        switch interval {
        case .seconds(let value): return Double(value)
        case .milliseconds(let value): return Double(value) / 1_000
        case .microseconds(let value): return Double(value) / 1_000_000
        case .nanoseconds(let value): return Double(value) / 1_000_000_000
        case .never: return 0
        @unknown default: return 0
        }
    }

    func testEveryAuthorizedRetryCanSurviveOneLostHandshake() throws {
        // The floor is derived from the engine, not chosen. boringtun sends the handshake
        // initiation once and does not retry until REKEY_TIMEOUT — 5 s, and no longer: the
        // 0–333 ms of jitter the WireGuard paper specifies is described in the comment above
        // boringtun/src/noise/timers.rs:228 and NOT implemented by the line below it, which
        // is a bare `elapsed() >= REKEY_TIMEOUT`. A window shorter than that buys exactly one
        // initiation and zero retransmits, so a single lost datagram — the ordinary reason a
        // handshake fails — makes the attempt unable to recover while it spends the rest of
        // the outage budget.
        //
        // At the old floor of 1 s, 8 of the reachable retry decisions were in that position.
        // Read from the vendored engine rather than restated. A literal here would let a
        // change to boringtun's cadence pass unnoticed: the policy's floor and the test's
        // expectation would drift apart independently and the suite would stay green while
        // authorized retries again expired before the first retransmission.
        let timers = try readSource(.wireGuardCoreVendoredTimers)
        let match = try XCTUnwrap(
            timers.range(
                of: #"REKEY_TIMEOUT: Duration = Duration::from_secs\((\d+)\)"#,
                options: .regularExpression),
            "REKEY_TIMEOUT is no longer declared the way this test reads it"
        )
        let engineRetransmitSeconds = try XCTUnwrap(
            Int(timers[match].split(separator: "(").last?.dropLast() ?? ""),
            "could not read REKEY_TIMEOUT's value"
        )
        XCTAssertGreaterThan(engineRetransmitSeconds, 0)
        for elapsed in 0...Policy.maximumBlackholeSeconds {
            for attempts in 0...5 {
                guard case .retry(_, _, let deadline) = Policy.decision(
                    completedAttempts: attempts, elapsedSeconds: elapsed,
                    cause: try Self.sessionEnd(.connectionExpired))
                else { continue }
                XCTAssertGreaterThan(
                    deadline, engineRetransmitSeconds,
                    "attempts=\(attempts) elapsed=\(elapsed) authorized a \(deadline)s window, "
                        + "which ends before the engine retransmits"
                )
            }
        }
    }

    func testAPoisonedLockEarnsAnotherAttemptButADeterministicFaultDoesNot() throws {
        // These two policies have to agree. ChainedDataPathPolicy classifies engineInternal
        // as `.reconnect` — the one engine fault worth retrying, because a fresh session
        // gets a fresh lock — while unrecognized and sessionCreationFailed are deterministic:
        // a fresh session runs the same code to the same answer. Surrendering on
        // engineInternal here contradicted the classifier and discarded a recoverable case.
        guard case .retry = try decide(cause: .engineInternal)
        else { return XCTFail("a poisoned lock should earn a fresh session") }

        for cause in [WireGuardEngineError.unrecognized(code: -99), .sessionCreationFailed] {
            XCTAssertEqual(
                try decide(cause: cause),
                .fallBackToDNSOnly(reason: .engineUnusable),
                "\(cause) is deterministic — retrying spends the budget for nothing"
            )
        }
    }

    func testTheBudgetIsEnforceableFromTheStartOfAnOutage() {
        // The gap this closes: `decision` is only consulted when a session ENDS, and the
        // engine does not end one promptly — boringtun retransmits an in-flight handshake
        // for REKEY_ATTEMPT_TIME (90 s) before reporting connectionExpired. So on the FIRST
        // loss of reachability the policy is not consulted for a minute and a half, and a
        // deadline attached to a rebuilt session never gets the chance to fire. A per-attempt
        // deadline alone therefore could not enforce the advertised 15 s.
        //
        // remainingBlackholeSeconds is what a watchdog armed at outage start uses, and it
        // must be answerable before any decision exists.
        XCTAssertEqual(
            Policy.remainingBlackholeSeconds(elapsedSeconds: 0),
            Policy.maximumBlackholeSeconds,
            "at outage start the whole budget is available"
        )
        for elapsed in 0...Policy.maximumBlackholeSeconds {
            XCTAssertEqual(
                Policy.remainingBlackholeSeconds(elapsedSeconds: elapsed),
                Policy.maximumBlackholeSeconds - elapsed
            )
        }

        // Saturates rather than going negative or trapping — a watchdog that fired late must
        // still get a sane answer.
        for elapsed in [Policy.maximumBlackholeSeconds, 100, 10_000, Int.max] {
            XCTAssertEqual(Policy.remainingBlackholeSeconds(elapsedSeconds: elapsed), 0)
        }
        for elapsed in [-1, -10_000, Int.min] {
            XCTAssertEqual(
                Policy.remainingBlackholeSeconds(elapsedSeconds: elapsed),
                Policy.maximumBlackholeSeconds,
                "negative elapsed is normalized, not trusted"
            )
        }
    }

    func testARetrysDeadlineIsAnUpperBoundNotAStandingPermission() throws {
        // The stale-deadline case: a decision made at elapsed 0 authorizes a 14 s window,
        // but the caller then waits `afterSeconds` before starting. Re-asking at the moment
        // the attempt actually begins must yield strictly less, or the budget silently
        // stretches by the delay.
        guard case .retry(let delay, _, let deadline) = Policy.decision(
            completedAttempts: 0, elapsedSeconds: 0, cause: try Self.sessionEnd(.connectionExpired))
        else { return XCTFail("expected a retry") }

        let atAttemptStart = Policy.remainingBlackholeSeconds(elapsedSeconds: delay)
        XCTAssertLessThan(
            atAttemptStart, Policy.maximumBlackholeSeconds,
            "the delay was spent and must count against the budget"
        )
        XCTAssertGreaterThanOrEqual(
            atAttemptStart, deadline,
            "the deadline issued with the decision must not exceed what is left when the "
                + "attempt starts"
        )
    }

    // MARK: - Builds that never produced a session

    /// Every build failure the factory can diagnose, taken from the suite that owns the triage
    /// rather than re-listed here — one list, for the same reason ``allTriagedCauses`` is one.
    private static let allBuildFailures = ChainedUpstreamSessionFactoryTests.allBuildFailures

    func testABuildFailuresOriginDecidesItRatherThanItsEngineError() {
        // A session that was never constructed has no engine verdict to carry: every build failure
        // reports `sessionCreationFailed` whatever went wrong, so the engine error holds none of
        // the factory's diagnosis. Classifying on it alone is what made a momentary handoff
        // indistinguishable from a rejected key, and answered both by ending chained mode for the
        // tunnel lifecycle.
        let transient = ChainedSessionEndCause.buildFailure(
            ChainedSessionBuildFailure.noEligibleInterface)
        let permanent = ChainedSessionEndCause.sessionCreationFailed

        XCTAssertEqual(
            transient.error, permanent.error,
            "the two build outcomes must be indistinguishable by engine error, or this test is "
                + "asserting something easier than the defect")
        XCTAssertNotEqual(transient.origin, permanent.origin)

        guard case .retry = Policy.decision(
            completedAttempts: 0, elapsedSeconds: 0, cause: transient)
        else { return XCTFail("a handoff with no eligible interface surrendered chained mode") }
        XCTAssertEqual(
            Policy.decision(completedAttempts: 0, elapsedSeconds: 0, cause: permanent),
            .fallBackToDNSOnly(reason: .engineUnusable))
    }

    func testAnErrorTheFactoryDidNotDiagnoseIsTreatedAsPermanent() {
        // `readCredentials` throws the secret store's own error, which travels unwrapped — so the
        // driver is handed errors this module has no classification for. Those must NOT acquire
        // the retry ladder by default: an unclassified fault given three attempts spends the
        // user's whole blackhole budget on a guess, and DNS-only still filters and still has
        // working internet.
        struct StoreUnavailable: Error {}
        XCTAssertEqual(
            Policy.decision(
                completedAttempts: 0, elapsedSeconds: 0, cause: .buildFailure(StoreUnavailable())),
            .fallBackToDNSOnly(reason: .engineUnusable))
        XCTAssertEqual(
            ChainedSessionEndCause.buildFailure(StoreUnavailable()).origin, .permanentBuildFailure)
    }

    func testATransientBuildFailureSpendsARungAgainstTheSameBudget() {
        // A rung, not a refund. The transient origin joins the ordinary retry arithmetic rather
        // than bypassing it: the same backoff, the same deadline shrinkage, and the same
        // surrender when what is left will not fit a useful attempt. An implementation that
        // returned `.retry` for a transient cause without consulting the budget would pass every
        // other test in this file.
        let transient = ChainedSessionEndCause.buildFailure(
            ChainedSessionBuildFailure.noEligibleInterface)

        XCTAssertEqual(
            Policy.decision(completedAttempts: 0, elapsedSeconds: 0, cause: transient),
            .retry(afterSeconds: 1, attempt: 1, attemptDeadlineSeconds: 14),
            "a transient build failure must schedule exactly what a failed handshake does")
        XCTAssertEqual(
            Policy.decision(completedAttempts: 1, elapsedSeconds: 14, cause: transient),
            .fallBackToDNSOnly(reason: .budgetExhausted),
            "the budget was extended for a build failure")

        // And it never authorizes more than what is left, at any point in an outage.
        for elapsed in 0...Policy.maximumBlackholeSeconds {
            for attempts in 0...5 {
                guard case .retry(let delay, _, let deadline) = Policy.decision(
                    completedAttempts: attempts, elapsedSeconds: elapsed, cause: transient)
                else { continue }
                XCTAssertLessThanOrEqual(
                    elapsed + delay + deadline, Policy.maximumBlackholeSeconds,
                    "attempts=\(attempts) elapsed=\(elapsed) overran the budget")
            }
        }
    }

    func testTheTwoPoliciesAgreeOnEveryEngineError() {
        // The invariant, rather than a list of cases: for every engine error, if the data-path
        // classifier says another attempt is not warranted, this policy must not authorize
        // one. Three separate contradictions between these two types have already shipped —
        // destinationBufferTooSmall, engineInternal, and the caller-contract trio — each found
        // in review rather than by a test, because each was asserted in one place and assumed
        // in the other.
        //
        // This test itself was the fourth. It used to open with `guard dataPath.endsSession
        // else { continue }`, which asserted NOTHING about the skipped causes — and the four it
        // skipped were the four that disagreed: protocolViolation, underLoad, noCurrentSession
        // and oversizedDatagram are `dropPacket`/`warrantsAnotherAttempt == false` on one side
        // and fell through to `.retry` on the other. A silent `continue` is not a scope
        // boundary, it is an unasserted branch; every cause now leaves an assertion behind.
        var comparedEndings = 0
        var comparedDrops = 0
        for cause in Self.allTriagedCauses {
            let dataPath = ChainedDataPathPolicy.action(for: .failure(cause))

            guard let ending = ChainedSessionEndCause(dataPath) else {
                // Not a session end. Assert that, rather than assuming it: the two ways of
                // asking — this initializer and the action's own predicates — must not drift.
                XCTAssertFalse(
                    dataPath.endsSession,
                    "\(cause) ends the session but yields no ChainedSessionEndCause, so the "
                        + "reconnect policy can never be told about it"
                )
                XCTAssertFalse(dataPath.warrantsAnotherAttempt, "\(cause)")
                comparedDrops += 1
                continue
            }
            XCTAssertTrue(
                dataPath.endsSession,
                "\(cause) yields a session-end cause but claims not to end the session"
            )

            let reconnect = Policy.decision(
                completedAttempts: 0, elapsedSeconds: 0, cause: ending)
            let authorizesRetry: Bool
            if case .retry = reconnect { authorizesRetry = true } else { authorizesRetry = false }

            XCTAssertEqual(
                authorizesRetry, dataPath.warrantsAnotherAttempt,
                "\(cause): data path says warrantsAnotherAttempt=\(dataPath.warrantsAnotherAttempt) "
                    + "but the reconnect policy \(authorizesRetry ? "retries" : "surrenders")"
            )
            comparedEndings += 1
        }
        // Both arms must actually run. Without this the test passes if every cause takes the
        // same branch — including the degenerate case where a refactor makes nothing
        // constructible and the loop asserts eleven trivial falsehoods.
        XCTAssertEqual(comparedEndings, 7, "session-ending causes compared")
        XCTAssertEqual(comparedDrops, 4, "per-packet causes checked for unreachability")

        // THE SECOND CLASSIFIER, and the reason the invariant above had to be scoped to engine
        // verdicts. A build failure never reached the data path — there was no session for it to
        // run in — so `ChainedDataPathPolicy` has nothing to say about it and the counterpart
        // authority is the factory's own `warrantsAnotherAttempt`. Leaving the new origin outside
        // every agreement check is how the first contradiction got in: `noEligibleInterface` said
        // transient in one file while the driver and this policy said permanent in two others,
        // and no test compared them.
        var comparedBuilds = 0
        for failure in Self.allBuildFailures {
            let decision = Policy.decision(
                completedAttempts: 0, elapsedSeconds: 0, cause: .buildFailure(failure))
            let authorizesRetry: Bool
            if case .retry = decision { authorizesRetry = true } else { authorizesRetry = false }
            XCTAssertEqual(
                authorizesRetry, failure.warrantsAnotherAttempt,
                "\(failure): the factory says warrantsAnotherAttempt="
                    + "\(failure.warrantsAnotherAttempt) but the reconnect policy "
                    + "\(authorizesRetry ? "retries" : "surrenders")")
            comparedBuilds += 1
        }
        XCTAssertEqual(comparedBuilds, 7, "a build failure was added without triaging it here")
        XCTAssertTrue(
            Self.allBuildFailures.contains { $0.warrantsAnotherAttempt },
            "no build failure is transient, so this loop asserts seven identical surrenders")
        XCTAssertTrue(
            Self.allBuildFailures.contains { !$0.warrantsAnotherAttempt },
            "no build failure is permanent, so a rejected key now spends the whole budget")
    }

    func testPerPacketVerdictsCannotReachTheReconnectPolicy() {
        // The structural half of the fix above. Agreement between the policies is no longer
        // something a test has to catch after the fact for these four: there is no value of
        // ChainedSessionEndCause that carries them, so `decision` cannot be called with one.
        //
        // Read from the classifier rather than restated, so adding a fifth per-packet verdict
        // extends this automatically instead of leaving it silently partial.
        for cause in Self.allTriagedCauses {
            let action = ChainedDataPathPolicy.action(for: .failure(cause))
            guard case .dropPacket = action else { continue }
            XCTAssertNil(
                ChainedSessionEndCause(action),
                "\(cause) is a per-packet drop; building a session-end cause from it would let "
                    + "one hostile datagram surrender chained mode for the whole lifecycle"
            )
        }

        // Non-error outcomes are not session ends either — a drain loop asks this of every
        // action it gets, not only of failures.
        for operation in [
            WireGuardOperation.none, .writeToNetwork(byteCount: 32),
            .writeToTunnelIPv4(byteCount: 40), .writeToTunnelIPv6(byteCount: 60),
        ] {
            XCTAssertNil(
                ChainedSessionEndCause(ChainedDataPathPolicy.action(for: .success(operation))),
                "\(operation) is normal traffic, not a session end"
            )
        }

        // The one origin that cannot come through an action at all: the session was never
        // constructed, so no data-path outcome exists to classify.
        XCTAssertEqual(ChainedSessionEndCause.sessionCreationFailed.error, .sessionCreationFailed)
    }

    func testAForgedSessionEndingActionIsRejected() {
        // The hole in the first version of the narrowing. `ChainedDataPathAction` is public and
        // its cases carry an arbitrary payload, so `.reconnect(reason: .underLoad)` is a value
        // any caller can write — and reading only the outer case accepted it, handing the
        // reconnect policy exactly the per-packet errors the type exists to keep away from it.
        //
        // The tests above could not catch it: they build actions by running the classifier, so
        // they only ever produce honest pairings. This one forges them deliberately.
        for cause in Self.allTriagedCauses {
            let honest = ChainedDataPathPolicy.action(for: .failure(cause))
            for forged in [
                ChainedDataPathAction.reconnect(reason: cause),
                ChainedDataPathAction.callerBug(reason: cause),
            ] where forged != honest {
                XCTAssertNil(
                    ChainedSessionEndCause(forged),
                    "\(forged.logValue) is not what the classifier produces for \(cause) "
                        + "(\(honest.logValue)) — accepting it reopens the route the type closes"
                )
            }
        }

        // Spelled out for the four that matter, so a refactor of the loop above cannot quietly
        // stop covering them.
        for packetLevel in [
            WireGuardEngineError.protocolViolation, .underLoad, .noCurrentSession,
            .oversizedDatagram,
        ] {
            XCTAssertNil(ChainedSessionEndCause(.reconnect(reason: packetLevel)), "\(packetLevel)")
            XCTAssertNil(ChainedSessionEndCause(.callerBug(reason: packetLevel)), "\(packetLevel)")
        }

        // And the honest pairings still work — the check must not be a blanket refusal.
        XCTAssertNotNil(ChainedSessionEndCause(.reconnect(reason: .connectionExpired)))
        XCTAssertNotNil(ChainedSessionEndCause(.callerBug(reason: .invalidArgument)))
    }

    func testCallerContractFailuresSurrenderRatherThanRebuild() throws {
        // Rebuilding a session does not change a malformed argument or an undersized buffer,
        // so retrying spends the outage budget on something deterministic. Surrendering names
        // its own cause: a field log saying callerContractViolation points at our packet loop,
        // not at the engine.
        for cause in [
            WireGuardEngineError.invalidArgument, .destinationBufferTooSmall, .packetTooLarge,
        ] {
            XCTAssertEqual(
                try decide(cause: cause),
                .fallBackToDNSOnly(reason: .callerContractViolation),
                "\(cause) is our bug — rebuilding retains it"
            )
        }
        XCTAssertEqual(
            try decide(cause: .invalidArgument).logValue,
            "fall-back-dns-only-callerContractViolation"
        )
    }

    func testOnlyBudgetExhaustedIsResolvableByANetworkChange() {
        // Gates hands-free auto-recovery (Slice 2): only a budget spent reaching an unreachable
        // peer can be cleared by a new network; engine/contract/clock faults cannot (Codex, PR #569).
        XCTAssertTrue(ChainedReconnectPolicy.Surrender.budgetExhausted.isResolvableByNetworkChange)
        XCTAssertFalse(ChainedReconnectPolicy.Surrender.engineUnusable.isResolvableByNetworkChange)
        XCTAssertFalse(
            ChainedReconnectPolicy.Surrender.callerContractViolation.isResolvableByNetworkChange)
        XCTAssertFalse(ChainedReconnectPolicy.Surrender.clockUnusable.isResolvableByNetworkChange)
    }

    /// The marker is written in one process and read as a gate in the next, and the two used to
    /// build and match the reason string independently. A reader that guesses the shape classifies
    /// every surrender as unrecognised — which fails closed into "never recoverable", the outcome
    /// nobody would notice because it looks exactly like the old behaviour.
    func testOnlyARecoverableSurrenderMarkerPermitsADNSOnlyStart() {
        // The writer's own output is what the reader must accept — asserted through the shared
        // member rather than a literal, so a change to either side fails here.
        XCTAssertTrue(
            ChainedReconnectPolicy.Surrender.markerReasonIsRecoverableSurrender(
                ChainedReconnectPolicy.Surrender.budgetExhausted.markerReason(suppressionPersisted: true)))

        for surrender in [
            ChainedReconnectPolicy.Surrender.engineUnusable,
            .callerContractViolation,
            .clockUnusable,
        ] {
            XCTAssertFalse(
                ChainedReconnectPolicy.Surrender.markerReasonIsRecoverableSurrender(
                    surrender.markerReason),
                "\(surrender) is not lifted by a network change")
        }

        // Markers the startup contract wrote carry a latch refusal, not a surrender. They are not
        // suppressions anyone has argued is safe to start DNS-only under.
        for foreign in ["upstreamUnavailable", "deviceStateUnavailable", "", "chained-surrendered:"] {
            XCTAssertFalse(
                ChainedReconnectPolicy.Surrender.markerReasonIsRecoverableSurrender(foreign),
                "\(foreign) is not a recognised surrender marker")
        }
    }
}
