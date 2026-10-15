import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class SnapshotCompileGateTests: XCTestCase {
    /// A minimal actor that records the maximum number of bodies running at once. If the gate
    /// ever lets two compiles overlap, `maxConcurrent` climbs above 1.
    private actor ConcurrencyTracker {
        private(set) var active = 0
        private(set) var maxConcurrent = 0

        func enter() {
            active += 1
            maxConcurrent = max(maxConcurrent, active)
        }

        func leave() {
            active -= 1
        }
    }

    func testOverlappingCompilesNeverRunConcurrently() async throws {
        let gate = SnapshotCompileGate()
        let tracker = ConcurrencyTracker()

        // Fire many submissions "at once" — each body suspends (Task.yield) while inside the
        // gate, which is precisely where a bare actor would let the next one interleave.
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<20 {
                group.addTask {
                    _ = try? await gate.run { () -> Int in
                        await tracker.enter()
                        // Yield several times to widen the overlap window a real await opens.
                        for _ in 0..<5 { await Task.yield() }
                        await tracker.leave()
                        return id
                    }
                }
            }
        }

        let maxConcurrent = await tracker.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1, "The gate must run at most one compile body at a time.")
    }

    func testGateReturnsEachSubmissionsOwnResult() async throws {
        let gate = SnapshotCompileGate()

        var results: [Int] = []
        for id in 0..<10 {
            let value = try await gate.run { () -> Int in
                await Task.yield()
                return id * 7
            }
            results.append(value)
        }

        XCTAssertEqual(results, (0..<10).map { $0 * 7 })
    }

    func testThrowingBodyRethrowsWithoutBreakingTheChain() async throws {
        struct CompileFailure: Error, Equatable {}
        let gate = SnapshotCompileGate()

        // A body that throws must surface its error to its own caller...
        do {
            _ = try await gate.run { () -> Int in
                await Task.yield()
                throw CompileFailure()
            }
            XCTFail("A throwing compile body must rethrow to its caller.")
        } catch {
            XCTAssertEqual(error as? CompileFailure, CompileFailure())
        }

        // ...and the chain must keep working for the next submission (the tail task itself
        // never throws — it captures the outcome — so a failed compile doesn't wedge the gate).
        let next = try await gate.run { () -> Int in
            await Task.yield()
            return 99
        }
        XCTAssertEqual(next, 99)
    }

    func testQueuedStaleReadsAreRejectedBeforeDecodeAndTheLatestReadStillRuns() async throws {
        let gate = SnapshotCompileGate()
        let fixture = PendingReadFixture()
        let owner = Task { try await gate.run { await fixture.holdOwner() } }
        await fixture.waitForOwner()
        let followers = (0..<20).map { _ in
            Task {
                try await gate.run(validating: { try await fixture.validate() }) {
                    await fixture.decode()
                }
            }
        }
        // Every follower remains stale whether it has entered the queue already
        // or reaches the gate after retirement. None may allocate a snapshot.
        await fixture.retire()
        await fixture.releaseOwner()
        _ = try await owner.value
        for follower in followers {
            do {
                _ = try await follower.value
                XCTFail("A retired read must not decode a snapshot.")
            } catch is CancellationError {} catch {
                XCTFail("Unexpected validation error: \(error)")
            }
        }
        let staleDecodes = await fixture.decodeCount
        XCTAssertEqual(staleDecodes, 0)
        let latest = try await gate.run(validating: {}) { await fixture.decode() }
        XCTAssertEqual(latest, 1, "Rejected stale work must not wedge the latest read.")
    }

    func testValidationObservesTheStateAfterThePredecessorFinishes() async throws {
        let gate = SnapshotCompileGate()
        let fixture = PendingReadFixture()
        let owner = Task { try await gate.run { await fixture.holdOwner() } }
        await fixture.waitForOwner()
        let follower = Task {
            try await gate.run(validating: { try await fixture.requireFinishedOwner() }) { 42 }
        }
        await fixture.releaseOwner()
        _ = try await owner.value
        let result = try await follower.value
        XCTAssertEqual(result, 42)
    }

    func testRetiredResultIsReleasedBeforeTheNextLoadStarts() async throws {
        let gate = SnapshotCompileGate()
        let fixture = PendingReadFixture()
        let lifetime = SnapshotLifetime()
        let owner = Task {
            try await gate.run(validating: { try await fixture.validate() }) {
                let snapshot = lifetime.makeSnapshot()
                await fixture.holdOwner()
                return snapshot
            }
        }
        defer { withExtendedLifetime(owner) {} }
        await fixture.waitForOwner()
        await fixture.retire()
        let successor = Task { try await gate.run { lifetime.liveCount } }
        await fixture.releaseOwner()
        do {
            _ = try await owner.value
            XCTFail("A retired decoded result must not escape the gate.")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected validation error: \(error)")
        }
        let liveAtNextLoad = try await successor.value
        XCTAssertEqual(liveAtNextLoad, 0, "Retired decoded storage must be released before the next load.")
    }

    private final class SnapshotProbe: Sendable {
        private let release: @Sendable () -> Void
        init(release: @Sendable @escaping () -> Void) { self.release = release }
        deinit { release() }
    }

    private final class SnapshotLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var liveCount: Int { lock.withLock { count } }
        func makeSnapshot() -> SnapshotProbe {
            lock.withLock { count += 1 }
            return SnapshotProbe { [self] in lock.withLock { count -= 1 } }
        }
    }

    private actor PendingReadFixture {
        private var ownerStarted = false
        private var ownerFinished = false
        private var current = true
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var decodeCount = 0

        func holdOwner() async {
            ownerStarted = true
            await withCheckedContinuation { continuation = $0 }
            ownerFinished = true
        }

        func waitForOwner() async {
            while !ownerStarted { await Task.yield() }
        }

        func releaseOwner() { continuation?.resume(); continuation = nil }
        func retire() { current = false }
        func validate() throws { if !current { throw CancellationError() } }
        func requireFinishedOwner() throws { if !ownerFinished { throw CancellationError() } }
        func decode() -> Int { decodeCount += 1; return decodeCount }
    }
}
