import XCTest
@testable import LavaSecCore

final class BiometricAuthenticationCoalescerTests: XCTestCase {
    // Fan-out A: a second `.appSettings` caller that arrives while a biometric prompt is already up
    // must share it, not raise a second Face ID prompt. Proven by the coalesced caller's own evaluator
    // never being invoked. (Codex/OCR review on lavasec-ios#69.)
    @MainActor
    func testConcurrentAttemptsShareOneEvaluation() async {
        let coalescer = BiometricAuthenticationCoalescer()
        var firstEvaluatorInvocations = 0
        var secondEvaluatorInvocations = 0
        var release: CheckedContinuation<Bool, Never>?

        // First caller: its evaluator parks on `release`, so the single evaluation stays in flight
        // across the second caller's arrival.
        let first = Task { @MainActor in
            await coalescer.authenticate {
                firstEvaluatorInvocations += 1
                return await withCheckedContinuation { release = $0 }
            }
        }
        // Deterministic on the main-actor executor: yield until the first evaluator has started and
        // parked (its continuation captured into `release`).
        while release == nil {
            await Task.yield()
        }

        // Second caller arrives WHILE the first evaluation is in flight — it must coalesce onto it and
        // never invoke its own evaluator.
        let second = Task { @MainActor in
            await coalescer.authenticate {
                secondEvaluatorInvocations += 1
                return false
            }
        }
        // Let `second` run to its `await inFlight.value`; on the single-threaded main actor one yield is
        // enough (the first evaluation is parked), two is margin.
        await Task.yield()
        await Task.yield()

        // Complete the one outstanding evaluation; both callers resume with its result.
        release?.resume(returning: true)
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertEqual(firstEvaluatorInvocations, 1, "the in-flight evaluation runs exactly once")
        XCTAssertEqual(
            secondEvaluatorInvocations, 0,
            "a caller that arrives mid-flight must NOT raise a second prompt (fan-out A)"
        )
        XCTAssertTrue(firstResult, "the running caller gets its evaluation's result")
        XCTAssertTrue(secondResult, "the coalesced caller shares the SAME result")
    }

    @MainActor
    func testSequentialAttemptsEachRunTheirOwnEvaluation() async {
        let coalescer = BiometricAuthenticationCoalescer()
        var invocations = 0
        let evaluate: @MainActor () async -> Bool = {
            invocations += 1
            return true
        }
        _ = await coalescer.authenticate(evaluate)
        _ = await coalescer.authenticate(evaluate)
        XCTAssertEqual(
            invocations, 2,
            "once an evaluation completes the gate is clear — a later attempt is not stale-coalesced"
        )
    }

    @MainActor
    func testResultPropagatesUnchanged() async {
        let coalescer = BiometricAuthenticationCoalescer()
        let denied = await coalescer.authenticate { false }
        let allowed = await coalescer.authenticate { true }
        XCTAssertFalse(denied, "a failed evaluation returns false to the caller")
        XCTAssertTrue(allowed, "a successful evaluation returns true to the caller")
    }
}
