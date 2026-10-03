import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

@MainActor
final class ProtectionStatusRefreshCoordinatorTests: XCTestCase {
    func testCoalescedFollowerAwaitsOwnerAndItsBoundedFollowUp() async {
        let coordinator = ProtectionStatusRefreshCoordinator()
        let gate = RefreshPassGate()
        var ownerFinished = false
        var followerFinished = false

        let owner = Task { @MainActor in
            await coordinator.run {
                await gate.runPass()
            }
            ownerFinished = true
        }
        await gate.waitUntilStarted(passCount: 1)

        let follower = Task { @MainActor in
            await coordinator.run {
                XCTFail("A coalesced caller must join the owner rather than start an independent refresh.")
            }
            followerFinished = true
        }
        await Task.yield()
        XCTAssertFalse(followerFinished)

        gate.releaseNextPass()
        await gate.waitUntilStarted(passCount: 2)
        XCTAssertFalse(ownerFinished)
        XCTAssertFalse(followerFinished, "The follower must await the queued follow-up, not only the first pass.")

        gate.releaseNextPass()
        await owner.value
        await follower.value

        XCTAssertTrue(ownerFinished)
        XCTAssertTrue(followerFinished)
        XCTAssertEqual(gate.startedPassCount, 2)
    }

    func testFollowerArrivingDuringFollowUpAwaitsOwnerWithoutStartingThirdPass() async {
        let coordinator = ProtectionStatusRefreshCoordinator()
        let gate = RefreshPassGate()
        var lateFollowerFinished = false

        let owner = Task { @MainActor in
            await coordinator.run {
                await gate.runPass()
            }
        }
        await gate.waitUntilStarted(passCount: 1)

        let firstFollower = Task { @MainActor in
            await coordinator.run {
                XCTFail("A coalesced caller must not start an independent refresh.")
            }
        }
        await Task.yield()
        gate.releaseNextPass()
        await gate.waitUntilStarted(passCount: 2)

        let lateFollower = Task { @MainActor in
            await coordinator.run {
                XCTFail("A follower during the bounded follow-up must still join the current owner.")
            }
            lateFollowerFinished = true
        }
        await Task.yield()
        XCTAssertFalse(lateFollowerFinished)

        gate.releaseNextPass()
        await owner.value
        await firstFollower.value
        await lateFollower.value

        XCTAssertTrue(lateFollowerFinished)
        XCTAssertEqual(gate.startedPassCount, 2, "Coalescing must stay bounded to one follow-up pass.")
    }
}

@MainActor
private final class RefreshPassGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var startedPassCount = 0

    func runPass() async {
        startedPassCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted(passCount: Int) async {
        while startedPassCount < passCount {
            await Task.yield()
        }
    }

    func releaseNextPass() {
        precondition(!continuations.isEmpty)
        continuations.removeFirst().resume()
    }
}
