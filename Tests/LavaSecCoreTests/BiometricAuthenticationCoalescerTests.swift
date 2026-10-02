import XCTest
@testable import LavaSecCore

final class BiometricAuthenticationCoalescerTests: XCTestCase {
    @MainActor
    func testRevokedTurnCannotPublishASuccessfulBiometricResult() async {
        let coalescer = BiometricAuthenticationCoalescer()
        var revision: UInt64 = 0
        var finish: CheckedContinuation<Bool, Never>?
        let old = Task { @MainActor in
            await coalescer.authenticate(scope: 0, isCurrent: { revision == 0 }) {
                await withCheckedContinuation { finish = $0 }
            }
        }
        while finish == nil { await Task.yield() }
        revision = 1
        finish?.resume(returning: true)
        let result = await old.value
        XCTAssertFalse(result, "A successful old OS prompt is not a grant for the new turn")
    }

    @MainActor
    func testNewTurnWaitsForOldPromptThenCoalescesOnlyItsOwnEvaluation() async {
        let coalescer = BiometricAuthenticationCoalescer()
        var revision: UInt64 = 0
        var oldFinish: CheckedContinuation<Bool, Never>?
        var newFinish: CheckedContinuation<Bool, Never>?
        var evaluations: [String] = []
        let old = Task { @MainActor in
            await coalescer.authenticate(scope: 0, isCurrent: { revision == 0 }) {
                evaluations.append("old")
                return await withCheckedContinuation { oldFinish = $0 }
            }
        }
        while oldFinish == nil { await Task.yield() }
        revision = 1
        let firstNew = Task { @MainActor in
            await coalescer.authenticate(scope: 1, isCurrent: { revision == 1 }) {
                evaluations.append("new")
                return await withCheckedContinuation { newFinish = $0 }
            }
        }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(evaluations, ["old"], "Never overlap OS prompts from different turns")
        oldFinish?.resume(returning: true)
        while newFinish == nil { await Task.yield() }
        let secondNew = Task { @MainActor in
            await coalescer.authenticate(scope: 1, isCurrent: { revision == 1 }) {
                evaluations.append("duplicate")
                return false
            }
        }
        await Task.yield()
        await Task.yield()
        newFinish?.resume(returning: true)
        let results = await (old.value, firstNew.value, secondNew.value)
        XCTAssertFalse(results.0)
        XCTAssertTrue(results.1)
        XCTAssertTrue(results.2)
        XCTAssertEqual(evaluations, ["old", "new"], "Old completion cleanup must not erase the new flight")
    }

    @MainActor
    func testRevokedWaitingTurnNeverStartsAReplacementPrompt() async {
        let coalescer = BiometricAuthenticationCoalescer()
        var revision: UInt64 = 1
        var finish: CheckedContinuation<Bool, Never>?
        var waitingEvaluations = 0
        let appUnlock = Task { @MainActor in
            await coalescer.authenticate {
                await withCheckedContinuation { finish = $0 }
            }
        }
        while finish == nil { await Task.yield() }
        let waiting = Task { @MainActor in
            await coalescer.authenticate(scope: 1, isCurrent: { revision == 1 }) {
                waitingEvaluations += 1
                return true
            }
        }
        await Task.yield()
        await Task.yield()
        revision = 2
        finish?.resume(returning: true)
        let unlockResult = await appUnlock.value
        let waitingResult = await waiting.value
        XCTAssertTrue(unlockResult, "A view-turn reset does not invalidate foreground App Unlock")
        XCTAssertFalse(waitingResult)
        XCTAssertEqual(waitingEvaluations, 0)
    }

    @MainActor
    func testForegroundAppUnlockAndViewTurnDoNotBorrowEachOthersResult() async {
        let coalescer = BiometricAuthenticationCoalescer()
        var finish: CheckedContinuation<Bool, Never>?
        var viewEvaluations = 0
        let appUnlock = Task { @MainActor in
            await coalescer.authenticate { await withCheckedContinuation { finish = $0 } }
        }
        while finish == nil { await Task.yield() }
        let view = Task { @MainActor in
            await coalescer.authenticate(scope: 0) {
                viewEvaluations += 1
                return false
            }
        }
        await Task.yield()
        await Task.yield()
        finish?.resume(returning: true)
        let unlockResult = await appUnlock.value
        let viewResult = await view.value
        XCTAssertTrue(unlockResult)
        XCTAssertFalse(viewResult)
        XCTAssertEqual(viewEvaluations, 1)
    }

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
