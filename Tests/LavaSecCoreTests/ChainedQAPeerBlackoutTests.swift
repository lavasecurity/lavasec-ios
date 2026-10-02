#if DEBUG || LAVA_QA_TOOLS
import XCTest
@testable import LavaSecChainedUpstream

final class ChainedQAPeerBlackoutTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 100
        func read() -> TimeInterval { lock.withLock { seconds } }
        func set(_ value: TimeInterval) { lock.withLock { seconds = value } }
    }

    private final class Channel: ChainedUpstreamDatagramChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (UnsafeRawBufferPointer) -> Void)?
        private var sends = 0
        private var closes = 0
        var counts: (Int, Int) { lock.withLock { (sends, closes) } }
        func send(_ packet: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
            lock.withLock { sends += 1 }
            completion(true)
        }
        func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
            lock.withLock { self.handler = handler }
        }
        func receive() {
            let callback = lock.withLock { handler }
            Data([1, 2, 3]).withUnsafeBytes { callback?($0) }
        }
        func close() { lock.withLock { closes += 1 } }
    }

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        func read() -> Int { lock.withLock { value } }
    }

    func testWindowExpiresWithoutTimerOrAppAndCannotBeRearmed() {
        let clock = Clock()
        let window = ChainedQAPeerBlackout(now: clock.read)
        XCTAssertFalse(window.shouldDrop(inbound: false))
        XCTAssertTrue(window.arm())
        XCTAssertTrue(window.shouldDrop(inbound: false))
        clock.set(119.999)
        XCTAssertTrue(window.shouldDrop(inbound: true))
        XCTAssertFalse(window.arm(), "a repeated IPC message must not extend the outage")
        clock.set(120)
        XCTAssertFalse(window.shouldDrop(inbound: false))
        XCTAssertFalse(window.shouldDrop(inbound: true))
        XCTAssertFalse(window.arm(), "one shot per provider even after expiry")
        XCTAssertEqual(window.counters().sent, 1)
        XCTAssertEqual(window.counters().received, 1)
    }

    func testReboundChannelSharesDeadlineAndLostSendsReleaseBackpressure() {
        let clock = Clock()
        let window = ChainedQAPeerBlackout(now: clock.read)
        let base = Channel()
        let first = ChainedQABlackoutChannel(base: base, blackout: window)
        let completed = Count()
        let received = Count()
        first.setReceiveHandler { _ in received.increment() }
        func send(_ channel: ChainedQABlackoutChannel) {
            Data([1, 2, 3]).withUnsafeBytes { bytes in
                channel.send(bytes) { accepted in if accepted { completed.increment() } }
            }
        }
        send(first)
        base.receive()
        XCTAssertTrue(window.arm())
        send(first)
        base.receive()
        XCTAssertEqual(base.counts.0, 1)
        XCTAssertEqual(received.read(), 1)
        XCTAssertEqual(completed.read(), 2)

        clock.set(115)
        let nextBase = Channel()
        let rebound = ChainedQABlackoutChannel(base: nextBase, blackout: window)
        rebound.setReceiveHandler { _ in received.increment() }
        send(rebound)
        nextBase.receive()
        XCTAssertEqual(nextBase.counts.0, 0)
        clock.set(120)
        send(rebound)
        nextBase.receive()
        XCTAssertEqual(nextBase.counts.0, 1)
        XCTAssertEqual(completed.read(), 4)
        XCTAssertEqual(received.read(), 2)
        XCTAssertEqual(window.counters().sent, 2)
        XCTAssertEqual(window.counters().received, 2)
        first.close()
        rebound.close()
        XCTAssertEqual(base.counts.1, 1)
        XCTAssertEqual(nextBase.counts.1, 1)
    }

    func testReplacementProviderHasNoInheritedFault() {
        let clock = Clock()
        let old = ChainedQAPeerBlackout(now: clock.read)
        XCTAssertTrue(old.arm())
        XCTAssertTrue(old.shouldDrop(inbound: false))
        let replacement = ChainedQAPeerBlackout(now: clock.read)
        XCTAssertFalse(replacement.shouldDrop(inbound: false))
    }
}
#endif
