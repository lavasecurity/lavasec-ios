import Dispatch
import LavaSecFilterPipeline
import XCTest

final class SnapshotReloadCoordinatorTests: XCTestCase {
    private let queue = DispatchSerialQueue(label: "snapshot-reload-coordinator-tests")

    func testBeginAdvancesGenerationAndMovesOwnershipToTheLatestReload() {
        let coordinator = SnapshotReloadCoordinator(queue: queue)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                XCTAssertFalse(isolated.isReloadInFlight)

                let first = isolated.begin()
                let second = isolated.begin()

                XCTAssertGreaterThan(second, first)
                XCTAssertFalse(isolated.isCurrent(first))
                XCTAssertTrue(isolated.isCurrent(second))
                XCTAssertTrue(isolated.isReloadInFlight)
            }
        }
    }

    func testStaleFinishDoesNotClearANewerOwner() {
        let coordinator = SnapshotReloadCoordinator(queue: queue)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let first = isolated.begin()
                let second = isolated.begin()

                isolated.finish(first)
                XCTAssertTrue(isolated.isReloadInFlight)

                isolated.finish(second)
                XCTAssertFalse(isolated.isReloadInFlight)
            }
        }
    }

    func testInvalidateSupersedesWorkAndClearsInFlightState() {
        let coordinator = SnapshotReloadCoordinator(queue: queue)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let beforeInvalidation = isolated.begin()
                let invalidationGeneration = isolated.invalidate()

                XCTAssertGreaterThan(invalidationGeneration, beforeInvalidation)
                XCTAssertTrue(isolated.isCurrent(invalidationGeneration))
                XCTAssertFalse(isolated.isCurrent(beforeInvalidation))
                XCTAssertFalse(isolated.isReloadInFlight)

                let afterInvalidation = isolated.begin()
                XCTAssertGreaterThan(afterInvalidation, invalidationGeneration)
                XCTAssertTrue(isolated.isReloadInFlight)

                isolated.finish(beforeInvalidation)
                XCTAssertTrue(isolated.isReloadInFlight)
                XCTAssertTrue(isolated.isCurrent(afterInvalidation))
            }
        }
    }

    func testAssumeIsolatedProvidesSynchronousOnQueueAccess() {
        let coordinator = SnapshotReloadCoordinator(queue: queue)

        queue.sync {
            coordinator.assumeIsolated { isolated in
                let generation = isolated.begin()
                XCTAssertTrue(isolated.isCurrent(generation))
                XCTAssertTrue(isolated.isReloadInFlight)

                isolated.finish(generation)
                XCTAssertFalse(isolated.isReloadInFlight)
            }
        }
    }
}
