import XCTest
@testable import LavaSecCore

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
}
