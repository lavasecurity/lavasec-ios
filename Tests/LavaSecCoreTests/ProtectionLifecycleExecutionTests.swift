import Foundation
import XCTest
@testable import LavaSecKit

@MainActor
final class ProtectionLifecycleExecutionTests: XCTestCase {
    private enum FenceKind: CaseIterable { case exclusive, owned, descendant }
    private enum Sentinel: Error { case original }

    func testEveryFenceObtainsExecutionTimeBeforeLockingAndUnlocksBeforeEndingIt() async throws {
        for kind in FenceKind.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let gate = CallbackGate()
            let work = Task { @MainActor in
                try await self.runFence(kind, fixture: fixture) {
                    XCTAssertTrue(fixture.active)
                    XCTAssertNil(try ProtectionLifecycleMutationFence.acquire(lockFileURL: fixture.url, wait: false))
                    await gate.wait()
                    return 42
                }
            }
            await gate.waitUntilStarted()
            XCTAssertTrue(fixture.active, "Execution time must survive Swift task suspension.")
            XCTAssertEqual(fixture.ends, 0)
            gate.release()
            let result = try await work.value
            XCTAssertEqual(result, 42)
            XCTAssertEqual(fixture.ends, 1)
            XCTAssertFalse(fixture.active)
        }
    }

    func testDeniedExecutionTimeNeverAcquiresTheFenceOrRunsTheOperation() async throws {
        for kind in FenceKind.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.admitted = false
            do {
                try await runFence(kind, fixture: fixture) { XCTFail("A denied operation must not run.") }
                XCTFail("Expected refusal.")
            } catch ProtectionLifecycleExecution.Failure.backgroundExecutionUnavailable {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
            XCTAssertEqual(fixture.ends, 0)
        }
    }

    func testExpirationDuringAdmissionDoesNotDispatchWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.expireDuringBegin = true
        do {
            try await runFence(.exclusive, fixture: fixture) { XCTFail("Already expired.") }
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.ends, 1)
    }

    func testExpirationCancelsAnOwnedWaitAndEndsAfterTheFenceIsReleased() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var waiting = false
        let work = Task { @MainActor in
            try await self.runFence(.exclusive, fixture: fixture) {
                waiting = true
                try await Task.sleep(for: .seconds(60))
                XCTFail("Expiration must interrupt a cancellable wait.")
            }
        }
        while !waiting { await Task.yield() }
        fixture.expire?()
        do { try await work.value; XCTFail("Expected cancellation.") } catch is CancellationError {}
        XCTAssertEqual(fixture.ends, 1)
    }

    func testExpirationDrainsNonCancellableCallbacksBeforeUnlockingAndEndingExecution() async throws {
        for kind in FenceKind.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let gate = CallbackGate()
            let work = Task { @MainActor in
                try await self.runFence(kind, fixture: fixture) { await gate.wait() }
            }
            await gate.waitUntilStarted()
            fixture.expire?()
            await Task.yield()
            XCTAssertTrue(fixture.active)
            XCTAssertEqual(fixture.ends, 0)
            XCTAssertNil(try ProtectionLifecycleMutationFence.acquire(lockFileURL: fixture.url, wait: false),
                         "A late platform callback still owns the mutation; cancellation is not completion.")
            gate.release()
            do { try await work.value; XCTFail("Expired work cannot publish success.") } catch is CancellationError {}
            XCTAssertEqual(fixture.ends, 1)
        }
    }

    func testExpirationWhileContendedNeverRunsTheQueuedMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Begin normally probes the unlocked inode to establish ordering. This test deliberately
        // starts with a different owner and checks that the queued operation remains lock-free.
        fixture.expectAvailableAtBegin = false
        fixture.expectAvailableAtEnd = false
        let owner = try XCTUnwrap(ProtectionLifecycleMutationFence.acquire(lockFileURL: fixture.url, wait: false))
        defer { owner.release() }
        let work = Task { @MainActor in
            try await self.runFence(.exclusive, fixture: fixture) { XCTFail("Expired waiter ran.") }
        }
        while !fixture.active { await Task.yield() }
        fixture.expire?()
        do { try await work.value; XCTFail("Expected cancellation.") } catch is CancellationError {}
        XCTAssertEqual(fixture.ends, 1)
        XCTAssertNil(try ProtectionLifecycleMutationFence.acquire(lockFileURL: fixture.url, wait: false))
    }

    func testCallerCancellationPropagatesAndStillDrainsTheCallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = CallbackGate()
        let work = Task { @MainActor in
            try await self.runFence(.owned, fixture: fixture) { await gate.wait() }
        }
        await gate.waitUntilStarted()
        work.cancel()
        await Task.yield()
        XCTAssertTrue(fixture.active)
        gate.release()
        do { try await work.value; XCTFail("Expected cancellation.") } catch is CancellationError {}
        XCTAssertEqual(fixture.ends, 1)
    }

    func testOperationErrorIsPreservedAndExecutionEndsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            try await runFence(.owned, fixture: fixture) { throw Sentinel.original }
            XCTFail("Expected operation error.")
        } catch Sentinel.original {}
        XCTAssertEqual(fixture.ends, 1)
    }

    private func runFence<T>(
        _ kind: FenceKind, fixture: Fixture,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        switch kind {
        case .exclusive:
            return try await ProtectionLifecycleMutationFence.withExclusiveMutation(
                lockFileURL: fixture.url, waitUntilAvailable: true,
                beginBackgroundExecution: fixture.begin, operation: operation)
        case .owned:
            return try await ProtectionLifecycleMutationFence.withOwnedMutation(
                lockFileURL: fixture.url, validateOwnership: { true },
                beginBackgroundExecution: fixture.begin, operation: operation)
        case .descendant:
            return try await ProtectionLifecycleMutationFence.withDescendantMutation(
                lockFileURL: fixture.url, validateLocalOwnership: { true }, validateExternalGeneration: { true },
                beginBackgroundExecution: fixture.begin, operation: operation)
        }
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var url: URL { directory.appendingPathComponent("lifecycle.lock") }
        var active = false
        var ends = 0
        var admitted = true
        var expireDuringBegin = false
        var expectAvailableAtBegin = true
        var expectAvailableAtEnd = true
        var expire: (@MainActor @Sendable () -> Void)?

        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: directory) }

        func begin(_ expire: @escaping @MainActor @Sendable () -> Void) -> ProtectionLifecycleExecution.End? {
            guard admitted else { return nil }
            if expectAvailableAtBegin { assertAvailable() }
            active = true
            self.expire = expire
            if expireDuringBegin { expire() }
            return {
                if self.expectAvailableAtEnd { self.assertAvailable() }
                self.ends += 1
                self.active = false
                self.expire = nil
            }
        }

        private func assertAvailable() {
            do {
                let fence = try XCTUnwrap(ProtectionLifecycleMutationFence.acquire(lockFileURL: url, wait: false))
                fence.release()
            } catch { XCTFail("Lifecycle lock still owned at assertion boundary: \(error)") }
        }
    }

    @MainActor
    private final class CallbackGate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func waitUntilStarted() async { while !started { await Task.yield() } }
        func release() { continuation?.resume(); continuation = nil }
    }
}
