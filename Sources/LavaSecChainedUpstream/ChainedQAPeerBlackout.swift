#if DEBUG || LAVA_QA_TOOLS
import Foundation

/// A one-shot, memory-only peer outage for device QA. Every channel in a provider
/// shares one window, so rebinding cannot reset or extend the twenty-second limit.
public final class ChainedQAPeerBlackout: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var beganAt: TimeInterval?
    private var sentDrops = 0
    private var receivedDrops = 0

    /// Uses monotonic uptime; a test supplies a controllable clock.
    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Arms once per provider instance, without writing configuration or preferences.
    @discardableResult public func arm() -> Bool {
        lock.withLock {
            guard beganAt == nil else { return false }
            beganAt = now()
            return true
        }
    }

    /// Counts actual discarded datagrams. Expiry is checked on every packet and
    /// does not depend on a timer, the app staying alive, or another IPC message.
    public func shouldDrop(inbound: Bool) -> Bool {
        lock.withLock {
            guard let beganAt else { return false }
            let elapsed = now() - beganAt
            guard elapsed >= 0, elapsed < 20 else { return false }
            if inbound { receivedDrops += 1 } else { sentDrops += 1 }
            return true
        }
    }

    /// Aggregate counters only; never stores packet contents or peer addresses.
    public func counters() -> (sent: Int, received: Int) {
        lock.withLock { (sentDrops, receivedDrops) }
    }
}

/// Simulates packet loss between the physical UDP socket and its peer. The real
/// channel still owns its socket, telemetry, close semantics, and interface binding.
public final class ChainedQABlackoutChannel: ChainedUpstreamDatagramChannel, @unchecked Sendable {
    private let base: ChainedUpstreamDatagramChannel
    private let blackout: ChainedQAPeerBlackout

    /// Wraps a normal channel; all replacements must receive the same blackout.
    public init(base: ChainedUpstreamDatagramChannel, blackout: ChainedQAPeerBlackout) {
        self.base = base
        self.blackout = blackout
    }

    /// A lost UDP packet was accepted by the transport, so it releases backpressure.
    public func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
        if blackout.shouldDrop(inbound: false) { completion(true) }
        else { base.send(datagram, completion: completion) }
    }

    /// Drops replies in the same window, without retaining borrowed buffers.
    public func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
        let blackout = blackout
        base.setReceiveHandler { packet in
            if !blackout.shouldDrop(inbound: true) { handler(packet) }
        }
    }

    /// The underlying channel's close remains idempotent.
    public func close() { base.close() }
}
#endif
