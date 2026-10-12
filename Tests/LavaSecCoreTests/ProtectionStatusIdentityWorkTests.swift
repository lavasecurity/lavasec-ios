import XCTest
@testable import LavaSecKit

final class ProtectionStatusIdentityWorkTests: XCTestCase {
    @MainActor func testSuccessfulIdentityReadAndAbsentRecord() async {
        for identity: String? in ["provider-A", nil] {
            let work = ProtectionStatusIdentityWork { identity }
            guard case .observed(let observed, let began) = await work.read() else { return XCTFail("Read timed out") }
            XCTAssertEqual(observed, identity)
            XCTAssertNotNil(began.bootSessionID)
        }
    }

    @MainActor func testWedgedReadDoesNotBlockCallerOrFreeItsPhysicalSlot() async {
        let hold = DispatchSemaphore(value: 0)
        let reads = Counter()
        defer { hold.signal() }
        let work = ProtectionStatusIdentityWork {
            reads.increment()
            hold.wait()
            return "provider-A"
        }
        let began = ContinuousClock().now
        for _ in 0..<3 {
            guard case .unavailable = await work.read(timeoutMilliseconds: 30) else { return XCTFail("Wedged read escaped expiry") }
        }
        XCTAssertLessThan(began.duration(to: .now), .seconds(1))
        XCTAssertEqual(reads.value, 1, "Expired clients cannot fan out more SecItem work")
    }

    @MainActor func testConcurrentReadersJoinTheSamePhysicalOperation() async {
        let hold = DispatchSemaphore(value: 0)
        let reads = Counter()
        let work = ProtectionStatusIdentityWork {
            reads.increment()
            hold.wait()
            return "provider-A"
        }
        let first = Task { await work.read() }
        let second = Task { await work.read() }
        try? await Task.sleep(for: .milliseconds(30))
        hold.signal()
        for task in [first, second] {
            guard case .observed(let identity, _) = await task.value else { return XCTFail("Shared read unavailable") }
            XCTAssertEqual(identity, "provider-A")
        }
        XCTAssertEqual(reads.value, 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
