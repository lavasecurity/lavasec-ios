import Foundation

/// Coalesces identity reads off the caller's executor. Client expiry never frees a wedged physical read.
public final class ProtectionStatusIdentityWork: @unchecked Sendable {
    /// The metadata observation begins before the read; newer foreign publications require revalidation.
    public enum Outcome: Sendable {
        case observed(providerLifecycleID: String?, startedAt: ProtectionStatusPublicationClock.Sample)
        case unavailable
    }
    private let lock = NSLock()
    private let operation: @Sendable () -> String?
    private var running = false
    private var nextID: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Outcome, Never>] = [:]

    /// Creates one process-owned physical slot for the same read-only resource.
    public init(operation: @escaping @Sendable () -> String?) { self.operation = operation }

    /// At most eight clients join the same physical read, each with a bounded response deadline.
    public func read(timeoutMilliseconds: Int = 2_000) async -> Outcome {
        await withCheckedContinuation { continuation in
            let admission: (UInt64, Bool)? = lock.withLock {
                guard waiters.count < 8 else { return nil }
                nextID &+= 1
                waiters[nextID] = continuation
                let starts = !running
                running = true
                return (nextID, starts)
            }
            guard let (id, starts) = admission else { continuation.resume(returning: .unavailable); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(max(1, timeoutMilliseconds))) {
                let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                waiter?.resume(returning: .unavailable)
            }
            if starts {
                DispatchQueue.global(qos: .utility).async {
                    let began = ProtectionStatusPublicationClock.capture()
                    let identity = self.operation()
                    let pending = self.lock.withLock {
                        let values = Array(self.waiters.values)
                        self.waiters.removeAll()
                        self.running = false
                        return values
                    }
                    for waiter in pending { waiter.resume(returning: .observed(providerLifecycleID: identity, startedAt: began)) }
                }
            }
        }
    }
}
