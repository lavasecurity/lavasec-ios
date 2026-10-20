import XCTest
@testable import LavaSecKit

private actor BackgroundScheduleFixture {
    typealias Request = BackgroundTaskScheduleCoordinator.Request
    var requests: [Request] = []
    var submissions: [Request] = []
    var failNext = false
    var pauseNextRead = false
    var readContinuation: CheckedContinuation<Void, Never>?
    var readStarted = false

    func seed(_ requests: [Request]) { self.requests = requests }
    func failNextSubmission() { failNext = true }
    func pauseRead() { pauseNextRead = true }
    func resumeRead() { readContinuation?.resume(); readContinuation = nil }
    func pending() async -> [Request] {
        if pauseNextRead {
            pauseNextRead = false
            readStarted = true
            await withCheckedContinuation { readContinuation = $0 }
        }
        return requests
    }
    func submit(_ request: Request) throws {
        if failNext { failNext = false; throw CocoaError(.fileWriteUnknown) }
        submissions.append(request)
        requests.removeAll { $0.identifier == request.identifier }
        requests.append(request)
    }
    func makeCoordinator(enabled: @escaping @Sendable (String) -> Bool = { _ in true }) -> BackgroundTaskScheduleCoordinator {
        BackgroundTaskScheduleCoordinator(pendingRequests: { await self.pending() },
            submit: { try await self.submit($0) }, isEnabled: enabled,
            now: { Date(timeIntervalSince1970: 1_000_000) })
    }
}

final class BackgroundTaskScheduleCoordinatorTests: XCTestCase {
    typealias Request = BackgroundTaskScheduleCoordinator.Request
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFrequentAppBackgroundsDoNotPostponeProcessingOrTopUp() async {
        let fixture = BackgroundScheduleFixture()
        let coordinator = await fixture.makeCoordinator()
        for (id, interval) in [("catalog", 43_200.0), ("warm", 7_200.0)] {
            let original = Request(identifier: id, earliestBeginDate: now.addingTimeInterval(interval))
            let first = await coordinator.schedule(original)
            XCTAssertEqual(first, .submitted)
            // Several days of hourly visits used to keep both tasks in the future.
            for hour in 1...72 {
                let result = await coordinator.schedule(.init(identifier: id,
                    earliestBeginDate: now.addingTimeInterval(Double(hour) * 3600 + interval)))
                XCTAssertEqual(result, .keptEarlierRequest)
            }
        }
        let submitted = await fixture.submissions
        XCTAssertEqual(submitted.count, 2)
    }

    func testRecoveryPullsProcessingForwardAndRoutineSchedulingCannotUndoIt() async {
        let fixture = BackgroundScheduleFixture()
        let coordinator = await fixture.makeCoordinator()
        let routine = Request(identifier: "catalog", earliestBeginDate: now.addingTimeInterval(43_200))
        await fixture.seed([routine])
        let recovery = Request(identifier: "catalog", earliestBeginDate: nil)
        let expedited = await coordinator.schedule(recovery)
        let later = await coordinator.schedule(routine)
        XCTAssertEqual(expedited, .submitted)
        XCTAssertEqual(later, .keptEarlierRequest)
        let pending = await fixture.requests
        XCTAssertEqual(pending, [recovery])
    }

    func testExistingSystemRequestSurvivesCoordinatorRecreation() async {
        let fixture = BackgroundScheduleFixture()
        await fixture.seed([.init(identifier: "catalog", earliestBeginDate: now.addingTimeInterval(-60))])
        let coordinator = await fixture.makeCoordinator()
        let outcome = await coordinator.schedule(.init(identifier: "catalog", earliestBeginDate: now))
        XCTAssertEqual(outcome, .keptEarlierRequest)
        let submitted = await fixture.submissions
        XCTAssertTrue(submitted.isEmpty)
    }

    func testImmediateRecoveryPreservesAlreadyEligibleDatedRequest() async {
        let fixture = BackgroundScheduleFixture()
        let overdue = Request(identifier: "catalog", earliestBeginDate: now.addingTimeInterval(-60))
        await fixture.seed([overdue])
        let coordinator = await fixture.makeCoordinator()
        for _ in 0..<3 {
            let outcome = await coordinator.schedule(.init(identifier: "catalog", earliestBeginDate: nil))
            XCTAssertEqual(outcome, .keptEarlierRequest)
        }
        let submitted = await fixture.submissions
        let pending = await fixture.requests
        XCTAssertTrue(submitted.isEmpty, "Immediate recovery must not replace an already-eligible system request.")
        XCTAssertEqual(pending, [overdue])
    }

    func testFailedSubmissionIsRetriedAndConsumedRequestIsRescheduled() async {
        let fixture = BackgroundScheduleFixture()
        let coordinator = await fixture.makeCoordinator()
        let request = Request(identifier: "catalog", earliestBeginDate: now)
        await fixture.failNextSubmission()
        let failed = await coordinator.schedule(request)
        let retried = await coordinator.schedule(request)
        await fixture.seed([]) // The OS launched the pending task.
        let next = await coordinator.schedule(request)
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(retried, .submitted)
        XCTAssertEqual(next, .submitted)
    }

    func testKillSwitchBlocksRecoverySubmission() async {
        let fixture = BackgroundScheduleFixture()
        let coordinator = await fixture.makeCoordinator(enabled: { _ in false })
        let outcome = await coordinator.schedule(.init(identifier: "catalog", earliestBeginDate: nil))
        XCTAssertEqual(outcome, .disabled)
        let submitted = await fixture.submissions
        XCTAssertTrue(submitted.isEmpty)
    }

    func testOverlappingReadsCannotLetRoutineRequestOverwriteRecovery() async {
        let fixture = BackgroundScheduleFixture()
        await fixture.pauseRead()
        let coordinator = await fixture.makeCoordinator()
        let recovery = Request(identifier: "catalog", earliestBeginDate: nil)
        let first = Task { await coordinator.schedule(recovery) }
        for _ in 0..<1_000 {
            if await fixture.readStarted { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let started = await fixture.readStarted
        XCTAssertTrue(started)
        let routine = Request(identifier: "catalog", earliestBeginDate: now.addingTimeInterval(43_200))
        let second = Task { await coordinator.schedule(routine) }
        for _ in 0..<1_000 {
            if await coordinator.queuedRequestCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let queued = await coordinator.queuedRequestCount
        XCTAssertEqual(queued, 1, "The second call must overlap the first system read.")
        await fixture.resumeRead()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .submitted)
        XCTAssertEqual(secondOutcome, .keptEarlierRequest)
        let pending = await fixture.requests
        XCTAssertEqual(pending, [recovery])
    }
}
